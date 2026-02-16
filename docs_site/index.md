---
layout: default
title: Home
nav_order: 1
---

<div class="page-header">
<h1 class="page-title">Gemba API Documentation</h1>
{% include search.html %}
</div>

GBA emulator frontend powered by [teek](https://github.com/jamescook/teek) and [libmgba](https://github.com/mgba-emu/mgba).

## Quick Links

- [Gemba::Core]({{ '/api/Gemba/Core/' | relative_url }}) - GBA emulation via libmgba
- [Gemba::Player]({{ '/api/Gemba/Player/' | relative_url }}) - Full-featured player
- [Gemba::Config]({{ '/api/Gemba/Config/' | relative_url }}) - User configuration

## Getting Started

```sh
# Play a ROM
gemba game.gba

# With options
gemba --scale 4 --fullscreen game.gba

# Headless recording
gemba record --frames 600 -o clip.grec game.gba

# Encode to video
gemba decode clip.grec
```

## Search

Use the search box above to find classes, modules, and methods.
