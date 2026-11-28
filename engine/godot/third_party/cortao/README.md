# CORTAO (vendored)

Circular Occluder Ray-Traced Ambient Occlusion by Daniel Isheden, MIT (LICENSE here). Source: https://github.com/theagentd/CORTAO,
reference implementation v1.0.3, commit 420b168d88dd6f9276077ba62f3711cac9d7b46c (15 Nov 2026).

- `CORTAO*.h`: the shader headers from src/shaders/, unchanged. Godot's GLSL compiler has no include path, so
  adapters/godot/cortao_effect.gd inlines them into the wrappers in look/cortao/.
- `occluder_24x24x16_r16ui.bin`: tables/occluder/24x24x16x16_R16_UINT.bin (16 rays, 24 x 24 x 16 texels of R16_UINT).
- `occluder_24x24x16_r32ui.bin`: tables/occluder/24x24x16x32_R32_UINT.bin (32 rays, R32_UINT).

Update: copy the new headers and table over these, keep the file names, run tools/cortao_check.gd.
