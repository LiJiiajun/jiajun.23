/*
 * main.c
 *
 *  Created on: 2026Äê4ÔÂ22ÈÕ
 *      Author: notch
 */

#include "text_mode_vga_color.h"
#include "palette_test.h"

int main() {
    paletteTest();
    textVGAColorScreenSaver();
    while (1) {}
    return 0;
}
