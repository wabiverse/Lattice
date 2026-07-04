// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "Lattice",
  platforms: [
    .macOS(.v14),
    .visionOS(.v1),
    .iOS(.v17),
    .tvOS(.v17),
    .watchOS(.v10)
  ],
  products: [
    .library(name: "Lattice", targets: ["Lattice"]),
    .library(name: "LatticeMetal", targets: ["LatticeMetal"]),
    .library(name: "LatticeUSD", targets: ["LatticeUSD"]),
    .executable(name: "LatticeDemo", targets: ["LatticeDemo"])
  ],
  dependencies: [
    .package(url: "https://github.com/wabiverse/swift-usd.git", branch: "dev")
  ],
  targets: [
    .target(name: "Lattice"),

    .target(
      name: "LatticeMetal",
      dependencies: [
        .target(name: "Lattice")
      ]
    ),

    .target(
      name: "LatticeUSD",
      dependencies: [
        .product(name: "OpenUSDKit", package: "swift-usd"),
        .target(name: "Lattice")
      ],
      cxxSettings: [
        .define("_LIBCPP_ABI_NO_COMPRESSED_PAIR_PADDING")
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),

    .executableTarget(
      name: "LatticeDemo",
      dependencies: [
        .target(name: "Lattice")
      ]
    ),

    .testTarget(
      name: "LatticeTests",
      dependencies: [
        .target(name: "Lattice")
      ],
      cxxSettings: [
        .define("_LIBCPP_ABI_NO_COMPRESSED_PAIR_PADDING")
      ],
    ),

    .testTarget(
      name: "LatticeUSDTests",
      dependencies: [
        .target(name: "Lattice"),
        .target(name: "LatticeUSD")
      ],
      cxxSettings: [
        .define("_LIBCPP_ABI_NO_COMPRESSED_PAIR_PADDING")
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    )
  ]
)
