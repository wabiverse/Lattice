// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "Lattice",
  platforms: [
    .macOS(.v15),
    .visionOS(.v1),
    .iOS(.v17),
    .tvOS(.v17),
    .watchOS(.v10)
  ],
  products: [
    .library(name: "LatticeCore", targets: ["LatticeCore"]),
    .library(name: "LatticeMetal", targets: ["LatticeMetal"]),
    .library(name: "LatticeOverlays", targets: ["LatticeOverlays"]),
    .library(name: "LatticeUSD", targets: ["LatticeUSD"]),
    .library(name: "lattice", targets: ["lattice"]),
    .executable(name: "LatticeDemo", targets: ["LatticeDemo"]),
    .executable(name: "LatticeHydraDemo", targets: ["LatticeHydraDemo"])
  ],
  dependencies: [
    .package(url: "https://github.com/wabiverse/swift-usd.git", from: "26.5.2"),
    .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0"),
  ],
  targets: [
    .target(
      name: "LatticeCore",
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),

    .target(
      name: "LatticeMetal",
      dependencies: [
        .target(name: "LatticeCore")
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),
  
    .target(
      name: "LatticeOverlays",
      dependencies: [
        .product(name: "OpenUSDKit", package: "swift-usd"),
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),

    .target(
      name: "LatticeUSD",
      dependencies: [
        .product(name: "OpenUSDKit", package: "swift-usd"),
        .target(name: "LatticeOverlays"),
        .target(name: "LatticeCore")
      ],
      cxxSettings: [
        .define("_LIBCPP_ABI_NO_COMPRESSED_PAIR_PADDING")
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),

    .target(
      name: "lattice",
      dependencies: [
        .product(name: "OpenUSDKit", package: "swift-usd"),
        .target(name: "LatticeCore"),
        .target(name: "LatticeMetal"),
        .target(name: "LatticeUSD")
      ]
    ),

    .executableTarget(
      name: "LatticeDemo",
      dependencies: [
        .product(name: "OpenUSDKit", package: "swift-usd"),
        .target(name: "LatticeCore"),
        .target(name: "LatticeMetal"),
        .target(name: "LatticeUSD"),
        .target(name: "lattice")
      ],
      cxxSettings: [
        .define("_LIBCPP_ABI_NO_COMPRESSED_PAIR_PADDING")
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),
    
    .executableTarget(
      name: "LatticeHydraDemo",
      dependencies: [
        .product(name: "OpenUSDKit", package: "swift-usd"),
        .product(name: "HydraKit", package: "swift-usd"),
        .target(name: "LatticeCore"),
        .target(name: "LatticeMetal"),
        .target(name: "LatticeUSD")
      ],
      cxxSettings: [
        .define("_LIBCPP_ABI_NO_COMPRESSED_PAIR_PADDING")
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),

    .testTarget(
      name: "LatticeTests",
      dependencies: [
        .target(name: "LatticeCore")
      ],
      cxxSettings: [
        .define("_LIBCPP_ABI_NO_COMPRESSED_PAIR_PADDING")
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),

    .testTarget(
      name: "LatticeUSDTests",
      dependencies: [
        .product(name: "OpenUSDKit", package: "swift-usd"),
        .target(name: "LatticeCore"),
        .target(name: "LatticeUSD")
      ],
      cxxSettings: [
        .define("_LIBCPP_ABI_NO_COMPRESSED_PAIR_PADDING")
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    )
  ],
  cxxLanguageStandard: .gnucxx17
)
