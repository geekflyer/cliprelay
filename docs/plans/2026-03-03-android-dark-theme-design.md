# Android Dark Theme — Website Aesthetic

## Color Mapping

| Element | Current (Light) | New (Dark) |
|---------|-----------------|------------|
| Screen background | `#E8F5F3` / `#D6F5EF` | `#111820` |
| Card background | `#FFFFFF` | `#182028` |
| Card border | Aqua low opacity | `#243038` default, aqua glow connected |
| Text primary | `#00796B` | `#E8E8ED` |
| Text secondary | Black 40-80% | `#6B6B7B` |
| Accent | `#00FFD5` | `#00FFD5` (unchanged) |
| System bars | Light teal | `#111820` |

## Visual Effects

1. Dot grid overlay — aqua dots, 22dp grid, ~12% opacity
2. Aurora glow — aqua radial on dark background
3. Card glow — aqua shadow intensifying on connected state
4. Gradient text — white-to-aqua on app title
5. Top border accent — aqua gradient line on cards

## Component Updates

- Status chip: dark surface, aqua border, light text
- Main card: dark surface, aqua border glow
- Buttons: solid aqua primary, aqua-border outline secondary
- Device nodes: dark boxes, aqua accents
- Switch: dark track, aqua thumb
- Beam canvas: same animations, dark-appropriate colors

## Unchanged

- All animations and motion
- Layout and component structure
- Typography sizes and weights
- Aqua accent color
