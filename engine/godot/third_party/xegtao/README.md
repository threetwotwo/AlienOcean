# XeGTAO (ported, not vendored)

XeGTAO by Intel (Filip Strugar, Steve Mccalla), MIT (LICENSE here). Source: https://github.com/GameTechDev/XeGTAO,
Source/Rendering/Shaders/XeGTAO.hlsli (master, fetched 28 Nov 2026).

look/cortao/gtao_main.glsl ports XeGTAO_MainPass (the slice march, horizon integral and bent normal) to GLSL on CORTAO's
depth / normal inputs; XeGTAO's own depth prefilter and denoiser are replaced by CORTAO's (third_party/cortao). Its
visibility-bitmask variant follows Therrien, Levesque, Gilet 2023 ("Screen Space Indirect Lighting with Visibility Bitmask").
Checks: tests/run_cortao.sh (CORTAO_ALGO=gtao / vbao).
