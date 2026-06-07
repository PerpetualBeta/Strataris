// Strataris — planet palettes.
//
// Each planet warps to a visually distinct world: its own sky gradient and
// terrain colour bands (water → beach → vegetation → rock → peaks). A curated
// set of moods, cycled by planet number, so every world looks intentional
// rather than randomly garish. Structures keep their own grey palette
// (Structure.stageLook) so they always read as artificial here.

import Foundation

struct PlanetTheme {
    let name: String                       // the colony world's name (a finite, named cluster)
    let skyTop: (UInt8, UInt8, UInt8)
    let skyHaze: (UInt8, UInt8, UInt8)     // horizon haze; distant terrain fades into this
    let water: (UInt8, UInt8, UInt8)
    let beach: (UInt8, UInt8, UInt8)
    let veg: (UInt8, UInt8, UInt8)
    let rock: (UInt8, UInt8, UInt8)
    let peak: (UInt8, UInt8, UInt8)

    // The cluster: a small, fixed set of named frontier colonies at the farthest
    // reaches of Earth's expansion. We cycle through them endlessly as the level
    // climbs — but each is a known world the player is sworn to defend.
    static let all: [PlanetTheme] = [
        // Demeter — Earthlike: blue sky, green hills, snow peaks.
        PlanetTheme(name: "Demeter",
                    skyTop: (40, 90, 170), skyHaze: (184, 203, 226),
                    water: (20, 55, 110), beach: (200, 190, 140),
                    veg: (66, 122, 54), rock: (118, 100, 82), peak: (236, 236, 242)),
        // Tantalus — rust desert: Martian, dusty pink sky.
        PlanetTheme(name: "Tantalus",
                    skyTop: (150, 92, 68), skyHaze: (226, 182, 150),
                    water: (70, 45, 32), beach: (205, 152, 104),
                    veg: (176, 96, 52), rock: (138, 78, 54), peak: (224, 186, 150)),
        // Boreas — ice world: pale blue sky, white-blue ground.
        PlanetTheme(name: "Boreas",
                    skyTop: (118, 150, 200), skyHaze: (222, 236, 246),
                    water: (96, 142, 172), beach: (202, 216, 226),
                    veg: (172, 196, 212), rock: (150, 166, 186), peak: (255, 255, 255)),
        // Pandora — toxic: sickly green sky and flora.
        PlanetTheme(name: "Pandora",
                    skyTop: (58, 116, 86), skyHaze: (192, 226, 168),
                    water: (40, 92, 70), beach: (152, 172, 92),
                    veg: (84, 164, 60), rock: (104, 122, 70), peak: (214, 228, 182)),
        // Vulcan — volcanic: dark ashen sky, lava, charred rock.
        PlanetTheme(name: "Vulcan",
                    skyTop: (54, 28, 36), skyHaze: (162, 92, 70),
                    water: (150, 52, 24), beach: (96, 64, 58),
                    veg: (78, 60, 58), rock: (62, 52, 52), peak: (128, 86, 74)),
        // Vesper — violet twilight: purple sky, lilac terrain.
        PlanetTheme(name: "Vesper",
                    skyTop: (52, 40, 92), skyHaze: (192, 162, 212),
                    water: (42, 42, 92), beach: (154, 132, 162),
                    veg: (114, 84, 146), rock: (92, 80, 112), peak: (214, 202, 228)),
    ]

    /// Map a (1-based) level onto its planet in the cluster — cycles endlessly.
    static func forPlanet(_ n: Int) -> PlanetTheme {
        let i = ((n - 1) % all.count + all.count) % all.count
        return all[i]
    }

    /// The name of the world the player is on at the given level.
    static func name(forLevel n: Int) -> String { forPlanet(n).name }
}
