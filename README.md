# TDV-5010_Firmware
Disassembled firmware of multiple versions of the TDV-5010 Firmware type 968551. Implementing a 122-key PS/2 Keyboard using an Intel 8051 controller. To verify no mistakes were made when dissasembling the source material, the code was re-assembled using ASEM-51 (https://plit.de/asem-51/) and compared to the original dumps.

Seven versions have been documented:

 * v1.4
 * v1.6
 * v1.7
 * v1.8
 * v1.9
 * v2.0
 * v2.1

Check out the particular git commits for exact version-differences, otherwise have a look below for a brief changelog.

# Layout

The following is the layout of the 967043 key-matrix, when used together with the 967042 or 968571 controller boards. The two unused positions in the matrix may have been reserved for unused keyhole-type interlock switches, and the state of these can be read by issuing a non-standard keyboard-command implemented in the firmware.

Keyboard keynames:

	+-------------------------------------------------------------------------------------------------+
	|                                                                   O   O   O                     |
	|                                                                                                 |
	|  G00 G01 G02 G03 G04 G05 ** G07 G08 G09 G10    G12 G13 G14 G15   G47 G48<G49   G51 G52 G53 G54  |
	|                                                                  F47 F48 F49   F51 F52 F53 F54  |
	|    E00 E01 E02 E03 E04 E05 E06 E07 E08 E09 E10 E11 E12 E13<E14   E47 E48 E49   E51 E52 E53 E54  |
	|  D99 D00 D01 D02 D03 D04 D05 D06 D07 D08 D09 D10 D11 D12   D13   D47 D48 D49   D51 D52 D53 D54  |
	|  C99  C00 C01 C02 C03 C04 C05 C06 C07 C08 C09 C10 C11 C12        C47 C48 C49   C51 C52 C53 C54^ |
	|    B99  B00 B01 B02 B03 B04 B05 B06 B07 B08 B09 B10   B11  B12   B47 B48 B49   B51 B52 B53 B54  |
	|  A99      A00                 A05                 A10      A12   A47 A48 A49     A51   A53      |
	|                                                                                                 |
	+-------------------------------------------------------------------------------------------------+

		<	= E13A, G48A
		^	= C54A (duplicates C54)
		**	= G06  (duplicates G05)

Keynames in key datatable:

	Key-index:
	00-0F	  B99  D99  C99  G00  E00  A00  A05  A47  A10  A51  A12  A49  ---  A48  G48A A99
	10-1F	  B00  D00  C00  G01  E01  B02  B12  B49  B47  A53  B48  B52  ---  B51  E13A B01
	20-2F	  C02  D01  C01  G02  E02  B03  B10  C47  B11  B54  D13  C49  B53  C48  D51  C51
	30-3F	  C04  D03  D04  G04  E04  B05  G15  G09  G10  C54A G14  F49  C53  G47  G48  C52
	40-4F	  C05  C06  D05  G05  E05  B07  F47  G12  E14  D54  G13  G51  D53  F48  G49  D52
	50-5F	  B04  D02  C03  G03  E03  B06  B09  C11  C10  E54  C12  D48  E53  D47  D49  E52
	60-6F	  C07  C08  D06  G07  E06  B08  E09  E08  E10  F54  E11  E48  F53  E47  F51  F52
	70-7F	  D09  D07  D08  G08  E07  C09  D12  D11  D10  G54  E12  E49  G53  E13  E51  G52

# v1.4

One of the first firmwares to be used in production. Dumped from a keyboard made in the later half of 1989. Controller is an Intel D8751, L9070024.

Known issues:
* Wrong scancode for key index 5Ah in scancode set 3 (scancode 5Ch used, copied over from scancode set 2. Should be scancode 53h, or eventually 5Dh with a US layout.)
* Set Key Mode command will end immediately after the mode of one key is set, with no Ack. This command is expected to keep accepting more keys until an Enable Scanning command is received.
* Key-Release for NOTIS keys in scancode set 1 will incorrectly be preceeded with a F0h (break-code prefix for scancode set 2 and 3), in addition to having the most signifficant bit set as expected.

# v1.6

An early version, dumped from a keyboard made in late 1989 using an AMD D87C51, B 016EBJZ NLB chip.

* Fixes the Set Key Mode command and scan-code set 1 issues from v1.4.
* Adds support for using ordinary num-pad keys if a navigation key is held and num-lock is on in scancode-set 1 and 2.
* Checks both data and clock lines for potential data-collission before transmitting.

# v1.7

Another early version, dumped from a keyboard made in early 1990 using an AMD D87C51, B 016EBJZ NLB chip.

* Fixes the scan-code set 3 issue from v1.4.
* Uses a slightly more robust check to detect potential data-collission, retrying the check should a collission happen.
* Introduces an issue where the keyboard assumes that the host will yield during a data collission, and the keyboard will as such immediately retry any failed transmission. This can lead to a communication deadlock between the keyboard and host, should the host not yield in such a situation.

# v1.8

Taken from a keyboard made in late 1990, using a MHS P-80C51 620 one-time programmable controller. 

* Smaller tweaks to optimize firmware size.
* Better handling of output scancode data buffer overflow.
* Adds a 1ms cooldown time between bytes being sent from the keyboard, to prevent the issue from v1.7.
* Introduces an issue that the data-line may not be released during the cooldown after a collission has been detected.

# v1.9

This version is taken from a keyboard made in late 1990, also with an AMD D87C51, B 016EBJZ NLB chip.

* Smaller tweaks to reduce technical debt in code.
* Fixes the data-line release issue from v1.8.

# v2.0

Dumped from a one-time-programmable controller, a P-80C51 993 from MHS datecoded week 14 of 1992.

* Ignore new keypresses if the output scancode data queue is full.
* Adds caching of any released shift-keys if the outgoing scancode data queue is full.

# v2.1

The version used in most keyboards of this type, and usually found with a one-time-programmable controller. Dumped from a keyboard made in week 45 of 1992, and controller is a P-80C51 AEY from MHS. This version has also been found in a P-80C51 BAP from MHS dated the 9th week of 1994.

* Uses a dedicated flag to disable keypress scanning, rather than disabling/enabling the clock interrupts themselves.
* Does no longer automatically resume key scanning (if disabled) after updating typematic timing settings or invoking the set-mode-for-all-keys command.
