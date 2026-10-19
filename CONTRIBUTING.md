# Contributing to open_blue_plus

Thanks for helping. This package was built with AI assistance and depends on
its users to stay current: every Android, iOS, macOS, Windows, BlueZ and
browser release can change Bluetooth behavior.

## Reporting a problem

Open an [issue](https://github.com/gaabrielricci/open_blue_plus/issues) with:

* platform and OS version, phone / computer / adapter model;
* the peripheral, if relevant;
* a minimal code sample;
* debug logs: `BleManager.instance.setLogLevel(BleLogLevel.debug)`.

## Submitting a change

1. Fork the repository and create a branch from `main`.
2. Make the change. Keep the public API identical on every platform: if a
   platform behaves differently, document it in [PROTOCOL.md](PROTOCOL.md)
   and in the README feature table.
3. Check it:
   ```sh
   flutter analyze
   flutter test
   ```
   For native changes, run the [example app](example) on a real device of
   that platform with a real peripheral.
4. Add a line to [CHANGELOG.md](CHANGELOG.md) and update the docs and
   [llms.txt](llms.txt) if the API changed.
5. Open a pull request describing what changed, why, and how you tested it
   (platforms and devices).

## AI-assisted contributions

Welcome. Using an assistant is how this project was built. Before opening a
pull request, make sure that:

* you have read and understand every line of the change;
* it was tested on the platforms it touches (say which in the PR);
* it follows [PROTOCOL.md](PROTOCOL.md) and does not copy code from other
  Bluetooth packages with incompatible licenses.

Point your assistant at [llms.txt](llms.txt), [PROTOCOL.md](PROTOCOL.md) and
the code of the platform you are changing before asking it for code.

## License

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
