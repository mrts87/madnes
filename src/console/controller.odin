package console

Standard_Controller_Button :: enum {
    A      = 0,
    B      = 1,
    Select = 2,
    Start  = 3,
    Up     = 4,
    Down   = 5,
    Left   = 6,
    Right  = 7,
}

OUTPUT_REGISTER_1 :: 0x4016
OUTPUT_REGISTER_2 :: 0x4017

INPUT_REGISTER :: OUTPUT_REGISTER_1

Standard_Controller_Input :: bit_set[Standard_Controller_Button]

Standard_Controller :: struct {
    input:          Standard_Controller_Input,

    // Tracks the currently pressed buttons on the controller.
    // If input polling has been enabled, the data from the buffer gets copied
    // into `input`.
    input_buffer:   Standard_Controller_Input,

    // Used to track which button stored in `input` will be reported
    // by the Controller Output register.
    current_button: u8,
}

// Checks the first bit in the input register to see whether
// The program should keep track of the currently pressed buttons.
should_poll_input :: proc(input_register: u8) -> bool {
    return (input_register & 0x01) != 0
}

/// Returns the status of the controller, checking one button per read.
read_controller :: proc(controller: ^Standard_Controller) -> u8 {
    // The first 3-5 bits of the value are usually not driven, usually making the base value 0x40
    controller_output: u8 = 0x40

    // Pin D0: Controller's buttons


    return controller_output
}
