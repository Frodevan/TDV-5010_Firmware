

        Patch for Tandberg TDV-5000
        Frodevan, 2023-01-13
        Release 0.2


        Tandberg TDV-5000 series keyboard firmware v2.1, patched to make the extra
        keys useable on modern PCs and operaing-systems. To use this, burn it to an
        empty Intel 8751 (or other 8051-compatible), and replace the controller in
        the keyboard itself. Will only work with Tandberg-produced keyboards using
        Siemens-style switches (will NOT work with the later Cherry-OEM boards).



        Key                         Set 1       Set 2       Set 3       Function
        -----------------------------------------------------------------------------
        /\/\/\                      E0 5B       E0 1F       8B          GUI L
        [Stroked down-arrow]        E0 5D       E0 2F       8D          App

        MERK                        64          08          90          F13
        ANGRE                       65          10          91          F14
        SKRIV                       66          18          92          F15
        SLUTT                       67          20          93          F16
        STRYK                       68          28          94          F17
        KOPI                        69          30          95          F18
        FLYTT                       6A          38          96          F19
        FELT                        6B          40          97          F20
        AVSN                        6C          48          98          F21
        SETN                        6D          50          99          F22
        ORD                         6E          57          9A          F23
        HJELP                       7F          5F          9B          F24

        [Sideways u-turn arrow]     E0 08       E0 3D       9F          Undo [Legacy]

        >> <<                       E0 2E       E0 21       A1          Vol-
        <> ><                       E0 30       E0 32       A2          Vol+
        JUST                        E0 22       E0 34       A5          Play/Pause

        |<---                       E0 6A       E0 38       B2          WWW Back
        --->|                       E0 69       E0 30       B3          WWW Forward


        Table with new scancodes for NOTIS-keys, along with new key functions.

        Please note that except for the GUI/App keys, Set 3 scancodes are very non-
        standard since I was unable to find good info on media-keys for this set.
        The firmware does not have the posibility to disable only set 3 for a key,
        so non-standard codes were used. If you have a keyboard-mapper, you might
        be able to work with this, but I can't promise anything. I will in any way
        recommend sticking with set 2 to get native support for these keys.

        After some testing, it was found that the Undo key won't work natively on
        more recent versions of Windows. However, its scancode can still be re-
        mapped to something more usefull. Included is a .reg file (stored as .txt)
        that will make the key become a volume-mute key instead, as well as a file
        to revert this (clear all scancode re-mapping).

        -----------------------------------------------------------------------------

        Changelog:

                r0.2: Fixing type of extended scancode patched keys. They were
                      previously adding the pre- and post-fixes used with the
                      navigation keys, and despite it working on my computer,
                      it might potentially confuse the PC keyboard-controller.
                      After this release these keys will produce clean extended
                      scancodes with no unexpected pre/postfixes.
