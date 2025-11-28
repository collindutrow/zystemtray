# Zystemtray (`ztray`)

Small helper to launch, hide, and control console applications from the Windows system tray.

> **NOTICE**
> 
> Not intended (currently) for GUI applications, GUI applications are unsupported.

Target platform: **Windows only**.

## Build

Zig Version:

- Zig **0.15.2**

Dependencies:

- [zig-clap](https://github.com/Hejsil/zig-clap)
- [zigwin32](https://github.com/marlersoft/zigwin32)

Build:

```shell
zig build
```

Build and basic debugging:
```powershell
zig build -Doptimize=Debug && ./zig-out/bin/ztray.exe -pm ping.exe -- 127.0.0.1 -t; $LASTEXITCODE
```

Build Release:

```powershell
zig build-exe -Doptimize=ReleaseSafe
```

Executable output:

```text
zig-out\bin\ztray.exe
```

## Command-line usage

```text
ztray [options] <program> [-- <program-args>...]
```

- `<program>`: path to the target executable or script to launch.
- Everything after `--` (if present) is passed to `<program>` unchanged.
- If `--` is omitted, all remaining *positional* arguments are passed to `<program>`, this does not include *options*.

### Options

- `-i, --icon <path>`
   Path to a `.ico` file to use as the tray icon.
   
   (If omitted, the target executable's, `ztrays`, or default Win32 application icon will be used (in that order.))
   
- `-t, --tooltip <text>`
   Tooltip text for the tray icon.
   (If omitted, the executable name of `<program>` is used.)
   
- `-m, --minimized`
   Start the target application hidden.
   
- `-p, --persistent`

   Keep the *target* process alive when closing `ztray`.

- `-h, --help`
   Show usage help and exit.

## Examples

### Run `ping` under the tray

```
ztray -m ping.exe -- 127.0.0.1 -t
```

Runs minimized (`-m`) to the Windows system tray.

### Run `ping` with a custom tray icon and tooltip

```
ztray -i C:\icons\network.ico -t "Network Monitor" ping.exe -- 127.0.0.1 -t
```

Applies a custom tray icon and tooltip.

## Process behavior

> **NOTICE**
>
> Each instance of `ztray.exe` results in at least three processes: the target process, its console host (`conhost.exe`), and `ztray.exe` itself.

- Launches `conhost.exe`, which in turn starts the *target* process.
- Hides own console window.
- Creates tray icon.
- Enables toggling *target* process's `conhost.exe` console window via tray icon.
- Exits automatically when *target* process exits.

## Tray behavior

- **Left-click** tray icon
   - If window was hidden:
      - Show and Activate window
   
   - If window was shown:
      - Hide window
   
- **Right-click** tray icon
  - Open context menu with:
    - **Exit**: closes `ztray.exe` and *target*, unless `--persistent`, in which case *target* is kept alive and shown.
- **Target exits**
   - When *target* process exits, `ztray` exits, removing the tray icon.

## Notes and limitations

- Working directory: the *target* program inherits `ztray`’s current working directory. Using `ztray` from **PATH** is the best option.
- Process lifetime: If the *target* process exits, `ztray` exits automatically.
