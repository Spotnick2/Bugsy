## Bugsy report BGY-70d98c58-3a57
**TestAddon** · error · 1 time · first 2025-11-17 17:20 UTC, last 2025-11-17 17:20 UTC
Client Forever 1.60.1 (70959), enUS · captured native · locals off

### What the player saw
- Doing: Opening mail on <player>-<realm>
- Happened: Nothing
- Expected: The inbox

### Error (first occurrence, build 70959, 2025-11-17 17:20 UTC)
Captured with TestAddon 1.2.3
    Interface/AddOns/TestAddon/Core.lua:42: <player>'s bag is nil | pipe

    [Interface/AddOns/TestAddon/Core.lua]:42: in function <Interface/AddOns/TestAddon/Core.lua:41>
    Interface/AddOns/TestAddon/Libs/LibGlass-1.0/LibGlass.lua:9: in function paint
    [C]: ?

### Involved (Bugsy's reading, not a verdict)
- Named by WoW: none
- In the stack: TestAddon; LibGlass-1.0 (library, copy in TestAddon)
- Appears involved: TestAddon (medium: heuristic: first addon frame from the top of the stack)
- Installed when this report was prepared: TestAddon 1.2.3

### Not included
- locals (off) · your character name replaced · your realm name replaced