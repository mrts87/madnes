package console

import "../formats"
import "./mappers"
import "core:fmt"
import "core:os"

PPU_WARMUP_CYCLE :: 29658

Console :: struct {
    cpu:          CPU,
    ppu:          PPU,
    mapper:       mappers.NROM, // TODO: Implement Mapper interface to support multiple cartridge types
    controller_1: Standard_Controller,
    controller_2: Standard_Controller,
}

console_new :: proc() -> Console {
    console := Console {
        cpu = cpu_new(),
        ppu = ppu_new(),
    }
    console.cpu.console = &console

    return console
}

console_delete :: proc(console: ^Console) {
    mappers.nrom_remove(&console.mapper)
}

// Loads the cartridge and resets the CPU to load the program counter
// from the reset vector.
console_load_cartridge :: proc(
    console: ^Console,
    file: ^formats.NES2_0_Format,
) {
    console.mapper = mappers.nrom_from_nes2(file)
    console.cpu.console = console
    pc_lo := cpu_mem_read(&console.cpu, 0xfffc)

    console.cpu.total_cycles += 1
    pc_hi := cpu_mem_read(&console.cpu, 0xfffd)
    console.cpu.total_cycles += 1

    pc_start := bytes_to_address(pc_lo, pc_hi)
    console.cpu.program_counter = pc_start
    console.cpu.total_cycles += 2
}

console_tick :: proc(console: ^Console) {
    // TODO: Please find a better way to handle memory reading across the entire console
    console.cpu.console = console

    cpu_tick(&console.cpu)

    for _ in 0 ..< console.cpu.cycle {
        // The PPU ticks 3 times for each CPU cycle
        ppu_tick(&console.ppu, console)
        ppu_tick(&console.ppu, console)
        ppu_tick(&console.ppu, console)
    }

    // Handle gamepads; update their input status and reset the current button while
    // the input register is active.
    if should_poll_input(cpu_peek_memory(&console.cpu, INPUT_REGISTER)) {
        console.controller_1.input = console.controller_1.input_buffer
        console.controller_1.current_button = 0

        console.controller_2.input = console.controller_2.input_buffer
        console.controller_2.current_button = 0
    }

    //ppu_tick(&console.ppu, console)

    if console.cpu.total_cycles >= PPU_WARMUP_CYCLE {
        ppu_init(&console.ppu)
    }
}
