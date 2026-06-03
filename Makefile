# Strataris: Galactic Colony Defence — first-person mesh-terrain shoot-'em-up.
#
# First NATIVE game in the Jorvik suite (the others — Star Raiders, Rescue
# on Fractalus, Centipede, Mr. Do!, Gauntlet — are HTML/canvas tributes).
# Built with swiftc + runtime-compiled Metal shaders; the terrain is a GPU
# triangle mesh rendered from a quaternion camera into a low-res framebuffer
# and upscaled nearest-neighbour for that period-correct pixelated look.
#
# Release pipeline delegated to the shared `release.mk` from
# PerpetualBeta/jorvik-release.
#
# NAME NOTE: the product name lives in BUNDLE_NAME / PRODUCT_NAME / BUNDLE_ID
# below (+ the enclosing folder). Nothing in the Swift sources hard-codes it.

BUNDLE_NAME      := Strataris
BUNDLE_TYPE      := app
PRODUCT_NAME     := Strataris.app
BUNDLE_ID        := cc.jorviksoftware.Strataris
BUILD_SYSTEM     := swiftc

# MetalKit pulls in Metal; QuartzCore gives us CACurrentMediaTime for the
# frame clock. simd is a Swift module (no -framework needed) and unused here.
SWIFT_FRAMEWORKS := Cocoa Metal MetalKit QuartzCore AVFoundation GameController

SWIFT_SOURCES    := main.swift \
                    AppDelegate.swift \
                    GameView.swift \
                    Renderer.swift \
                    Canvas2D.swift \
                    Terrain.swift \
                    Camera.swift \
                    InputState.swift \
                    Sprite.swift \
                    Mesh.swift \
                    Enemy.swift \
                    Structure.swift \
                    Combat.swift \
                    Smoke.swift \
                    Font.swift \
                    MeshTerrain.swift \
                    PlanetTheme.swift \
                    Projectile.swift \
                    TextImage.swift \
                    HighScores.swift \
                    AudioEngine.swift \
                    VoiceComms.swift \
                    Gamepad.swift \
                    GameSettings.swift \
                    FeatureFlags.swift \
                    SettingsSheet.swift \
                    KeyboardSheet.swift \
                    OptionsSheet.swift

PACKAGE_TYPE     := zip
ALSO_SHIP_PKG    := true
EMBEDDED_FRAMEWORKS := Sparkle
# Hardened runtime must allow loading the embedded Sparkle framework + its
# helper apps (same convention as SpaceMan / HawkEye / CopyLens).
ENTITLEMENTS     := Strataris.entitlements

include ../jorvik-release/release.mk
