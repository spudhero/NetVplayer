# Android dialog presentation

This directory contains NetVplayer's MIT-licensed Java desktop dialog and playback-context
presentation code and its offline contract tests. It contains no Provider implementation,
source configuration, host APK, Android framework or downloaded runtime.

The app resource is `NetVplayer/Sources/NetVplayerApp/Resources/AndroidPresentation/android-presentation.jar`.
Its adjacent provenance records the three public Java source digests, Java release 21 and
two separately supplied compile dependency digests. `script/android_presentation.py` pins
the reviewed archive bytes and permits only these presentation classes and their nested classes.

From the repository root:

```sh
python3 script/build_android_dialog_presentation.py --verify
python3 script/build_android_dialog_presentation.py --runtime /path/to/verified-runtime
```

Rebuilding requires JDK 21 and the exact `android-framework.jar` and `android-adapter.jar`
identified by the provenance. Supply them through the verified runtime; the build does not
download or authorize redistribution of those dependencies. The runtime must also contain
`desktop-ui-framework-provenance.json`. Compilation includes only the three listed sources,
and the deterministic ZIP contains only their `.class` files. Review archive changes and
update the explicit pin before distribution; changing a provenance JSON alone cannot permit
a different executable archive.

Run the optional native dialog contracts with:

```sh
python3 script/test_android_dialog_presentation.py --runtime /path/to/verified-runtime --output /tmp/new-dialog-test
```

Public export and application audits make an exception only for the exact verified resource.
Other JAR, DEX, APK, Provider payloads, default sources and internal experiment records remain
outside the application/source boundary. Historical experiment entrypoints reference these
canonical sources internally; they are excluded from public export.
