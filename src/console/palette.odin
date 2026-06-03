package console

import "core:fmt"
import "core:os"

import "mappers"

RGB_Color :: struct {
    r: u8,
    g: u8,
    b: u8,
}

BOTTOM_RIGHT_ATTRIB_TILE: u8 : 0xc0
BOTTOM_LEFT_ATTRIB_TILE: u8 : 0x30
TOP_RIGHT_ATTRIB_TILE: u8 : 0x0c
TOP_LEFT_ATTRIB_TILE: u8 : 0x03

SYSTEM_PALETTE_SIZE :: 64

/// The system palette stores all the colours a NES program
/// Could use for it's rendering.
/// The palette contains 64 entries, each stored in an RGB888 format.
System_Palette :: struct {
    entries: [SYSTEM_PALETTE_SIZE]RGB_Color,
}

System_Palette_File_Error :: enum {
    Ok,
    Not_Found,
    Out_Of_Memory,
}

read_palette_from_path :: proc(
    path: string,
) -> (
    System_Palette,
    System_Palette_File_Error,
) {
    palette_file, palette_read_error := os.read_entire_file_from_path(
        path,
        context.allocator,
    )
    defer delete(palette_file)

    sys_palette := System_Palette{}

    if palette_read_error != os.General_Error.None {
        switch (palette_read_error) {
        case .Not_Exist:
            return sys_palette, .Not_Found
        case .Out_Of_Memory:
            return sys_palette, .Out_Of_Memory
        }
    }

    sys_palette = read_palette_from_data(palette_file)
    return sys_palette, .Ok
}

read_palette_from_data :: proc(data: []u8) -> System_Palette {
    palette := System_Palette{}

    current_byte := 0

    for palette_entry_index in 0 ..< SYSTEM_PALETTE_SIZE {
        palette_entry := RGB_Color {
            r = data[current_byte],
            g = data[current_byte + 1],
            b = data[current_byte + 2],
        }

        current_byte += 3
        palette.entries[palette_entry_index] = palette_entry
    }

    return palette
}

/// Returns the base address for a palette selected from the attribute table
attrib_table_get_palette_address :: proc(ppu: ^PPU, index: u8) -> u16 {
    if index > 3 {
        fmt.eprintfln("Attribute Table contained a value above 3.")
        os.exit(-1)
    }

    return u16(BACKDROP_PALETTE_VRAM_START) + u16(0x0004 * index)
}

/// Uses the nametable address to get the attribute table address connected to it.
get_attrib_table_address :: proc(nametable_address: u16) -> u16 {
    if nametable_address != NAMETABLE_0 &&
       nametable_address != NAMETABLE_1 &&
       nametable_address != NAMETABLE_2 &&
       nametable_address != NAMETABLE_3 {
        fmt.eprintfln(
            "Address %x is not a valid nametable base address.",
            nametable_address,
        )
        os.exit(-1)
    }

    return nametable_address + PPU_NAMETABLE_SIZE
}

/// Maps the tile's x and y address to the attrib table, returning the palette assigned to it.
attrib_table_get_tile :: proc(
    ppu: ^PPU,
    mapper: ^mappers.NROM,
    attrib_table_addr: u16,
    tile_address: u16,
) -> u8 {
    address :=
        attrib_table_addr |
        (tile_address & 0x0c00) |
        ((tile_address >> 4) & 0x38) |
        ((tile_address >> 2) & 0x07)

    attribute := ppu_vram_read(ppu, mapper, address)

    COARSE_X_BITS :: 0x7
    COARSE_Y_BITS :: 0x38

    // Left half of the attribute
    if ((address & COARSE_X_BITS) == 0) {
        if ((address & COARSE_Y_BITS) == 0) {
            return attribute & TOP_LEFT_ATTRIB_TILE
        }

        return (attribute & BOTTOM_LEFT_ATTRIB_TILE) >> 4
    }

    // Right half of the attribute
    if ((address & COARSE_X_BITS) != 0) {
        if ((address & COARSE_Y_BITS) == 0) {
            return (attribute & TOP_RIGHT_ATTRIB_TILE) >> 2
        }

        return (attribute & BOTTOM_RIGHT_ATTRIB_TILE) >> 6
    }

    return 0
}

/// Looks at specified palette to fetch the stored reference to
/// The color created by the PPU.
palette_table_get_color :: proc(
    ppu: ^PPU,
    mapper: ^mappers.NROM,
    base_address: u16,
    index: u8,
) -> RGB_Color {
    if index > 3 {
        fmt.eprintfln("Requested palette index higher than 3.")
        os.exit(-1)
    }

    // First colors in a palette are the same between the backdrop and the sprite.
    if (base_address >= SPRITE_PALETTE_VRAM_START && index % 4 == 0) {
        backdrop_address := base_address - 0x0010
        entry := ppu_vram_read(ppu, mapper, base_address + u16(index))
        return ppu.system_palette.entries[entry]
    }

    entry := ppu_vram_read(ppu, mapper, base_address + u16(index))
    return ppu.system_palette.entries[entry]
}
