package console

import "core:fmt"
import "core:os"

import "mappers"

DEFAULT_STATUS: u8 : 0x24

CPU_MEM_SIZE: u16 : 0xffff

PROGRAM_ROM_START: u16 : 0x8000
PROGRAM_ROM_MIRROR: u16 : 0xc000

STACK_TOP: u8 : 0xfd
STACK_PAGE: u16 : 0x0100

CPU_Status_Flags :: enum {
    /// This bit checks whether the result of the last math operation was a negative value.
    Negative          = 7,
    Overflow          = 6,

    /// Unused bit, has no effect on the CPU beyond being always set to 1.
    Always_1          = 5,
    Break             = 4,

    /// The decimal mode is unused by the NES.
    Decimal_Mode      = 3,
    Interrupt_Disable = 2,

    /// The bit checks whether the result of the last math operation was a zero.
    Zero              = 1,
    Carry             = 0,
}

CPU_Status :: bit_set[CPU_Status_Flags]

CPU :: struct {
    // The pointer to the Console
    console:                  ^Console,
    status:                   CPU_Status,
    accumulator:              u8,
    reg_x:                    u8,
    reg_y:                    u8,
    stack_top:                u8,
    program_counter:          u16,
    memory:                   [int(CPU_MEM_SIZE) + 1]u8,

    // Instruction info

    // Whenever the SEI instruction gets called,
    // The update to the CPU status gets delayed to the start of the next instruction
    // So that an ongoing Interrupt could be finished.
    disable_interrupt_update: bool,
    interrupt_requested:      bool,
    nmi_requested:            bool,

    // Describes whether there's an ongoing interrupt.
    // Used to control an edge case where both the NMI and IRQ interrupts have been polled.
    _interrupt_ongoing:       bool,

    // The amount of cycles used to perform the instruction
    cycle:                    u8,
    instruction_set:          [INSTRUCTION_SET_SIZE]Instruction,

    // Debug
    total_cycles:             u64,
}

@(private)
mem_reset :: proc(cpu: ^CPU) {
    // TODO: The actual NES fills the memory with random values at start.
    // This is used by multiple games for RNG.
    // This should be configurable.
    for i := 0; i < auto_cast CPU_MEM_SIZE; i += 1 {
        cpu.memory[i] = 0
    }
}

cpu_new :: proc() -> CPU {
    cpu := CPU {
        status                   = transmute(CPU_Status)DEFAULT_STATUS,
        accumulator              = 0,
        reg_x                    = 0,
        reg_y                    = 0,
        stack_top                = STACK_TOP,
        program_counter          = PROGRAM_ROM_MIRROR,
        cycle                    = 0,
        instruction_set          = instruction_set_create(),
        total_cycles             = 0,
        disable_interrupt_update = false,
        interrupt_requested      = false,
        nmi_requested            = false,
    }

    mem_reset(&cpu)
    // The entire initialization process takes 7 cycles.
    cpu.total_cycles += 3

    return cpu
}

/// Converts two bytes in the little endian order into an u16 value.
bytes_to_address :: proc(hi: u8, lo: u8) -> u16 {
    hi := u16(hi)
    lo := u16(lo)
    word: u16 = u16(hi | (lo << 8))

    return word
}

/// Converts an u16 value into a tuple of two bytes.
/// The bytes are returned in the little endian order.
address_to_bytes :: proc(address: u16) -> (u8, u8) {
    hi := (address & 0xff)
    lo := address >> 8

    return u8(hi), u8(lo)
}

cpu_mem_read :: proc(cpu: ^CPU, address: u16) -> u8 {
    // Check the PPU
    ppu_accessed, ppu_byte := ppu_mem_read(
        &cpu.console.ppu,
        &cpu.console.mapper,
        address,
    )

    if ppu_accessed {
        return ppu_byte
    }

    return cpu_peek_memory(cpu, address)
}

/// Accessed the program's memory without affecting the registers
/// Of the console's components
@(private)
cpu_peek_memory :: proc(cpu: ^CPU, address: u16) -> u8 {
    // Check the controller registers
    if address == OUTPUT_REGISTER_1 {
        return read_controller(&cpu.console.controller_1)
    }

    if address == OUTPUT_REGISTER_2 {
        return read_controller(&cpu.console.controller_2)
    }

    // Check the cartridge
    cartridge_accessed, cartridge_byte := mappers.nrom_mem_read(
        &cpu.console.mapper,
        address,
    )

    if cartridge_accessed {
        return cartridge_byte
    }

    if address <= 0x07ff {
        return cpu.memory[address]
    }

    // RAM Mirror 1
    if address >= 0x0800 && address <= 0x0fff {
        return cpu.memory[address - 0x0800]
    }

    // RAM Mirror 2
    if address >= 0x1000 && address <= 0x17ff {
        return cpu.memory[address - 0x1000]
    }

    // RAM Mirror 3
    if address >= 0x1800 && address <= 0x1fff {
        return cpu.memory[address - 0x1800]
    }

    return cpu.memory[address]
}

cpu_mem_write :: proc(cpu: ^CPU, address: u16, value: u8) {
    // Check the PPU
    ppu_accessed := ppu_mem_write(
        &cpu.console.ppu,
        cpu.console,
        address,
        value,
    )

    if ppu_accessed {
        return
    }

    cartridge_accessed := mappers.nrom_mem_write(
        &cpu.console.mapper,
        address,
        value,
    )
    if cartridge_accessed {
        return
    }

    if address <= 0x07ff {
        cpu.memory[address] = value
    }

    // RAM Mirror 1
    if address >= 0x0800 && address <= 0x0fff {
        cpu.memory[address - 0x0800] = value
    }

    // RAM Mirror 2
    if address >= 0x1000 && address <= 0x17ff {
        cpu.memory[address - 0x1000] = value
    }

    // RAM Mirror 3
    if address >= 0x1800 && address <= 0x1fff {
        cpu.memory[address - 0x1800] = value
    }

    cpu.memory[address] = value
}

cpu_advance :: proc(cpu: ^CPU) {
    cpu.program_counter += 1
    cpu.cycle += 1
}

cpu_fetch :: proc(cpu: ^CPU) -> u8 {
    cpu_advance(cpu)
    return cpu_mem_read(cpu, cpu.program_counter)
}

cpu_instruction_trace :: proc(cpu: ^CPU, instruction: ^Instruction) {
    // Address, Opcode
    fmt.printf(
        "%x %x ",
        cpu.program_counter,
        cpu_peek_memory(cpu, cpu.program_counter),
    )

    // TODO: Addressing Mode
    #partial switch instruction.addressing_mode {
    case .Implied:
        fmt.printf("      ")
    case .Immediate,
         .Zero_Page,
         .Zero_Page_Y,
         .Zero_Page_X,
         .Indexed_Indirect,
         .Indirect_Indexed,
         .Relative:
        fmt.printf("%x    ", cpu.memory[cpu.program_counter + 1])
    case .Absolute, .Absolute_X, .Absolute_Y, .Indirect:
        fmt.printf(
            "%x %x ",
            cpu_peek_memory(cpu, cpu.program_counter + 1),
            cpu_peek_memory(cpu, cpu.program_counter + 2),
        )
    }
    // Opcode name
    fmt.printf(" %s ", instruction.name)
    #partial switch instruction.addressing_mode {
    case .Absolute:
        addr := bytes_to_address(
            cpu_peek_memory(cpu, cpu.program_counter + 1),
            cpu_peek_memory(cpu, cpu.program_counter + 2),
        )
        fmt.printf("$%x = $%x", addr, cpu_peek_memory(cpu, addr))
    case .Absolute_X:
        fmt.printf(
            "$%x,X ",
            bytes_to_address(
                cpu_peek_memory(cpu, cpu.program_counter + 1),
                cpu_peek_memory(cpu, cpu.program_counter + 2),
            ),
        )
    case .Absolute_Y:
        fmt.printf(
            "$%x,Y ",
            bytes_to_address(
                cpu_peek_memory(cpu, cpu.program_counter + 1),
                cpu_peek_memory(cpu, cpu.program_counter + 2),
            ),
        )
    case .Indirect:
        fmt.printf(
            "(%x) ",
            bytes_to_address(
                cpu_peek_memory(cpu, cpu.program_counter + 1),
                cpu_peek_memory(cpu, cpu.program_counter + 2),
            ),
        )
    case .Accumulator:
        fmt.printf("A ")
    case .Immediate:
        fmt.printf("#%x ", cpu_peek_memory(cpu, cpu.program_counter + 1))
    case .Zero_Page:
        fmt.printf("$%x ", cpu_peek_memory(cpu, cpu.program_counter + 1))
    case .Zero_Page_X:
        fmt.printf("$%x,X ", cpu_peek_memory(cpu, cpu.program_counter + 1))
    case .Zero_Page_Y:
        fmt.printf("$%x,Y ", cpu_peek_memory(cpu, cpu.program_counter + 1))
    case .Indexed_Indirect:
        fmt.printf("($%x,X) ", cpu_peek_memory(cpu, cpu.program_counter + 1))
    case .Indirect_Indexed:
        fmt.printf("($%x),Y ", cpu_peek_memory(cpu, cpu.program_counter + 1))
    case .Relative:
        fmt.printf("*.%d ", i8(cpu_peek_memory(cpu, cpu.program_counter + 1)))
    case .Implied:
        fmt.printf("     ")
    }

    // CPU values pre-execution
    fmt.printf(
        "            A:%x X:%x Y:%x P:%x, SP:%x Total Cycles: %d\n",
        cpu.accumulator,
        cpu.reg_x,
        cpu.reg_y,
        transmute(u8)cpu.status,
        cpu.stack_top,
        cpu.total_cycles,
    )
}

@(private)
goto_interrupt :: proc(cpu: ^CPU, interrupt_address: u16) {
    return_hi, return_lo := address_to_bytes(cpu.program_counter)
    cpu.cycle += 1

    stack_push(cpu, return_lo)
    cpu.cycle += 1

    stack_push(cpu, return_hi)
    cpu.cycle += 1

    cpu_status := cpu.status
    cpu_status += {.Break}

    stack_push(cpu, transmute(u8)cpu_status)
    cpu.status += {.Interrupt_Disable}

    cpu.cycle += 1

    pc_lo := cpu_mem_read(cpu, interrupt_address)
    cpu.cycle += 1
    pc_hi := cpu_mem_read(cpu, interrupt_address + 1)
    cpu.cycle += 1

    cpu.program_counter = bytes_to_address(pc_lo, pc_hi)
    cpu.cycle += 1

    cpu._interrupt_ongoing = true
}

cpu_tick :: proc(cpu: ^CPU) {
    cpu.cycle = 0

    if cpu.disable_interrupt_update {
        cpu.status += {.Interrupt_Disable}
        cpu.disable_interrupt_update = false
    }

    opcode := cpu_mem_read(cpu, cpu.program_counter)
    instruction := cpu.instruction_set[opcode]

    cpu_instruction_trace(cpu, &instruction)
    instruction.execute(cpu, instruction.addressing_mode)

    if cpu.nmi_requested && !cpu._interrupt_ongoing {
        goto_interrupt(cpu, 0xfffa)
        cpu.nmi_requested = false
    }

    if cpu.interrupt_requested && !cpu._interrupt_ongoing {
        goto_interrupt(cpu, 0xfffe)
        cpu.interrupt_requested = false
    }

    cpu.total_cycles += u64(cpu.cycle)
}

cpu_set_reg_x :: proc(cpu: ^CPU, value: u8) {
    cpu.reg_x = value
    status_check_zero(cpu, cpu.reg_x)
    status_check_negative(cpu, cpu.reg_x)
}

cpu_set_reg_y :: proc(cpu: ^CPU, value: u8) {
    cpu.reg_y = value
    status_check_zero(cpu, cpu.reg_y)
    status_check_negative(cpu, cpu.reg_y)
}

cpu_set_accumulator :: proc(cpu: ^CPU, value: u8) {
    cpu.accumulator = value
    status_check_zero(cpu, cpu.accumulator)
    status_check_negative(cpu, cpu.accumulator)
}

stack_push :: proc(cpu: ^CPU, value: u8) {
    stack_addr := STACK_PAGE + u16(cpu.stack_top)
    cpu.memory[stack_addr] = value
    cpu.stack_top -= 1
}

stack_pop :: proc(cpu: ^CPU) -> u8 {
    cpu.stack_top += 1
    stack_addr := STACK_PAGE + u16(cpu.stack_top)
    return cpu.memory[stack_addr]
}
