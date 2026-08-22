# minimap-autozoom v1.1.0

Automatically remembers the minimap zoom level you set in each zone.

Scroll to the zoom level you want and it will come back the next time you zone in.

## Install

Drop the folder into `Game/addons/` and type `/addon load minimap-autozoom`. You need the Minimap plugin running too.

Using [minimap-helper](https://github.com/mousseng/xitools/tree/master/addons/minimap-helper)? Unload it first, since both addons try to set the zoom. Your old manually set zoom levels are copied across automatically.

## Commands

None.

## Notes

Any zone you have not set yet starts at a 0.5 zoom level.

Zoom settings are shared across all characters. Set a zone once and it applies to everyone, including new characters. If you're upgrading from an older version, your existing character-specific settings will be merged into one shared list the first time you load this version.

## Thanks

To lin, whose minimap-helper is where the idea for this came from.

More addons @ https://github.com/AddonsXI
