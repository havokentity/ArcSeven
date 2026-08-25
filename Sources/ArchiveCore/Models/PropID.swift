// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte

import Foundation

/// A 7-Zip property identifier (`PROPID`), used both as a column identifier in the
/// file panes and as the key type for the property bags produced by the engines.
///
/// ## Why a `String`-backed struct rather than an `enum`
///
/// 7-Zip's property set is **open and format-dependent**: each archive handler
/// advertises its own property list through `GetNumberOfProperties` /
/// `GetPropertyInfo`, so the set of keys you get back for a `.zip` is not the set
/// you get back for a `.7z`, and a future handler may add keys we have never seen.
/// A closed `enum` would force lossy parsing; a `RawRepresentable` struct lets an
/// unknown key round-trip intact and still be displayed as a column.
///
/// The raw value is the **canonical 7-Zip display name** (`"Packed Size"`,
/// `"Physical Size"`, …). This is deliberate and load-bearing: those same strings
/// are what `7zz l -slt` emits on the left of `" = "`, so the raw value doubles as
/// the wire key for the CLI engine, and it is what a future in-process engine would
/// map its numeric `kpid*` constants onto.
///
/// The name table below is transcribed from the display strings in 7-Zip's
/// `CPP/7zip/UI/FileManager/PropertyName.rc` string table (`IDS_PROP_*`). Only the
/// human-readable names are reproduced — no 7-Zip code is copied. The `IDS_*`
/// symbol is recorded in a trailing comment purely so the mapping stays auditable.
public struct PropID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: StringLiteralType) { self.rawValue = value }

    /// The name shown in a column header or the Properties inspector.
    ///
    /// Identical to `rawValue` for every property in the table below; unknown
    /// properties simply display the key 7-Zip gave us.
    public var displayName: String { rawValue }

    /// `true` when this identifier is one 7-Zip is known to emit.
    public var isWellKnown: Bool { Self.wellKnownSet.contains(self) }
}

// MARK: - The property table

extension PropID {
    // Identity and layout
    public static let path: PropID                = "Path"                  // IDS_PROP_PATH
    public static let name: PropID                = "Name"                  // IDS_PROP_NAME
    public static let extensionName: PropID       = "Extension"             // IDS_PROP_EXTENSION
    public static let isFolder: PropID            = "Folder"                // IDS_PROP_IS_FOLDER
    public static let shortName: PropID           = "Short Name"            // IDS_PROP_SHORT_NAME
    public static let outName: PropID             = "Out Name"              // IDS_PROP_OUT_NAME
    public static let pathPrefix: PropID          = "Path Prefix"           // IDS_PROP_PREFIX
    public static let position: PropID            = "Position"              // IDS_PROP_POSITION
    public static let offset: PropID              = "Offset"                // IDS_PROP_OFFSET
    public static let fileType: PropID            = "Type"                  // IDS_PROP_FILE_TYPE
    public static let subType: PropID             = "SubType"               // IDS_PROP_SUBTYPE

    // Sizes
    public static let size: PropID                = "Size"                  // IDS_PROP_SIZE
    public static let packedSize: PropID          = "Packed Size"           // IDS_PROP_PACKED_SIZE
    public static let physicalSize: PropID        = "Physical Size"         // IDS_PROP_PHY_SIZE
    public static let headersSize: PropID         = "Headers Size"          // IDS_PROP_HEADERS_SIZE
    public static let totalPhysicalSize: PropID   = "Total Physical Size"   // IDS_PROP_TOTAL_PHY_SIZE
    public static let virtualSize: PropID         = "Virtual Size"          // IDS_PROP_VIRTUAL_SIZE
    public static let unpackSize: PropID          = "Unpack Size"           // IDS_PROP_UNPACK_SIZE
    public static let tailSize: PropID            = "Tail Size"             // IDS_PROP_TAIL_SIZE
    public static let embeddedStubSize: PropID    = "Embedded Stub Size"    // IDS_PROP_EMB_STUB_SIZE
    public static let totalSize: PropID           = "Total Size"            // IDS_PROP_TOTAL_SIZE
    public static let freeSpace: PropID           = "Free Space"            // IDS_PROP_FREE_SPACE
    public static let clusterSize: PropID         = "Cluster Size"          // IDS_PROP_CLUSTER_SIZE
    public static let sectorSize: PropID          = "Sector Size"           // IDS_PROP_SECTOR_SIZE
    public static let altStreamsSize: PropID      = "Alternate Streams Size" // IDS_PROP_ALT_STREAMS_SIZE

    // Timestamps
    public static let created: PropID             = "Created"               // IDS_PROP_CTIME
    public static let accessed: PropID            = "Accessed"              // IDS_PROP_ATIME
    public static let modified: PropID            = "Modified"              // IDS_PROP_MTIME
    public static let metadataChanged: PropID     = "Metadata Changed"      // IDS_PROP_CHANGE_TIME

    // Permissions and ownership
    public static let attributes: PropID          = "Attributes"            // IDS_PROP_ATTRIBUTES
    public static let posixMode: PropID           = "Mode"                  // IDS_PROP_POSIX_ATTRIB
    public static let readOnly: PropID            = "Read-only"             // IDS_PROP_READ_ONLY
    public static let user: PropID                = "User"                  // IDS_PROP_USER
    public static let group: PropID               = "Group"                 // IDS_PROP_GROUP
    public static let userID: PropID              = "User ID"               // IDS_PROP_USER_ID
    public static let groupID: PropID             = "Group ID"              // IDS_PROP_GROUP_ID
    public static let ntSecurity: PropID          = "NT Security"           // IDS_PROP_NT_SECURITY

    // Compression detail
    public static let solid: PropID               = "Solid"                 // IDS_PROP_SOLID
    public static let method: PropID              = "Method"                // IDS_PROP_METHOD
    public static let dictionarySize: PropID      = "Dictionary"            // IDS_PROP_DICTIONARY_SIZE
    public static let block: PropID               = "Block"                 // IDS_PROP_BLOCK
    public static let numBlocks: PropID           = "Blocks"                // IDS_PROP_NUM_BLOCKS
    public static let anti: PropID                = "Anti"                  // IDS_PROP_ANTI
    public static let splitBefore: PropID         = "Split Before"          // IDS_PROP_SPLIT_BEFORE
    public static let splitAfter: PropID          = "Split After"           // IDS_PROP_SPLIT_AFTER

    // Integrity
    public static let crc: PropID                 = "CRC"                   // IDS_PROP_CRC
    public static let checksum: PropID            = "Checksum"              // IDS_PROP_CHECKSUM
    public static let sha1: PropID                = "SHA-1"                 // IDS_PROP_SHA1
    public static let sha256: PropID              = "SHA-256"               // IDS_PROP_SHA256
    public static let isHash: PropID              = "IsHash"                // IDS_PROP_IS_HASH

    // Encryption / comments
    public static let encrypted: PropID           = "Encrypted"             // IDS_PROP_ENCRYPTED
    public static let commented: PropID           = "Commented"             // IDS_PROP_C0MMENTED (sic, upstream typo)
    public static let comment: PropID             = "Comment"               // IDS_PROP_COMMENT
    public static let shortComment: PropID        = "Short Comment"         // IDS_PROP_SHORT_COMMENT

    // Provenance
    public static let hostOS: PropID              = "Host OS"               // IDS_PROP_HOST_OS
    public static let fileSystem: PropID          = "File System"           // IDS_PROP_FILE_SYSTEM
    public static let creatorApplication: PropID  = "Creator Application"   // IDS_PROP_CREATOR_APP
    public static let version: PropID             = "Version"               // IDS_PROP_VERSION
    public static let codePage: PropID            = "Code Page"             // IDS_PROP_CODE_PAGE
    public static let identifier: PropID          = "ID"                    // IDS_PROP_ID
    public static let cpu: PropID                 = "CPU"                   // IDS_PROP_CPU
    public static let bit64: PropID               = "64-bit"                // IDS_PROP_BIT64
    public static let bigEndian: PropID           = "Big-endian"            // IDS_PROP_BIG_ENDIAN
    public static let characteristics: PropID     = "Characteristics"       // IDS_PROP_CHARACTS
    public static let virtualAddress: PropID      = "Virtual Address"       // IDS_PROP_VA

    // Volumes and counts
    public static let volume: PropID              = "Volume"                // IDS_PROP_VOLUME
    public static let isVolume: PropID            = "Multivolume"           // IDS_PROP_IS_VOLUME
    public static let numVolumes: PropID          = "Volumes"               // IDS_PROP_NUM_VOLUMES
    public static let volumeIndex: PropID         = "Volume Index"          // IDS_PROP_VOLUME_INDEX
    public static let volumeName: PropID          = "Label"                 // IDS_PROP_VOLUME_NAME
    public static let folders: PropID             = "Folders"               // IDS_PROP_FOLDERS
    public static let files: PropID               = "Files"                 // IDS_PROP_FILES
    public static let numStreams: PropID          = "Streams"               // IDS_PROP_NUM_STREAMS
    public static let numAltStreams: PropID       = "Alternate Streams"     // IDS_PROP_NUM_ALT_STREAMS
    public static let altStream: PropID           = "Alternate Stream"      // IDS_PROP_ALT_STREAM

    // Links and inodes
    public static let symbolicLink: PropID        = "Symbolic Link"         // IDS_PROP_SYM_LINK
    public static let hardLink: PropID            = "Hard Link"             // IDS_PROP_HARD_LINK
    public static let ntReparse: PropID           = "Link"                  // IDS_PROP_NT_REPARSE
    public static let copyLink: PropID            = "Copy Link"             // IDS_PROP_COPY_LINK
    public static let links: PropID               = "Links"                 // IDS_PROP_LINKS
    public static let inode: PropID               = "iNode"                 // IDS_PROP_INODE
    public static let streamID: PropID            = "Stream ID"             // IDS_PROP_STREAM_ID
    public static let deviceMajor: PropID         = "Device Major"          // IDS_PROP_DEVICE_MAJOR
    public static let deviceMinor: PropID         = "Device Minor"          // IDS_PROP_DEVICE_MINOR
    public static let devMajor: PropID            = "Dev Major"             // IDS_PROP_DEV_MAJOR
    public static let devMinor: PropID            = "Dev Minor"             // IDS_PROP_DEV_MINOR

    // Diagnostics
    public static let error: PropID               = "Error"                 // IDS_PROP_ERROR
    public static let errorType: PropID           = "Error Type"            // IDS_PROP_ERROR_TYPE
    public static let numErrors: PropID           = "Errors"                // IDS_PROP_NUM_ERRORS
    // IDS_PROP_ERROR_FLAGS (same display name upstream)
    public static let errorFlags: PropID          = "Errors"
    public static let warningFlags: PropID        = "Warnings"              // IDS_PROP_WARNING_FLAGS
    public static let warning: PropID             = "Warning"               // IDS_PROP_WARNING
    public static let isNotArchiveType: PropID    = "Is not archive type"   // IDS_PROP_IS_NOT_ARC_TYPE
    // IDS_PROP_PHY_SIZE_CANT_BE_DETECTED
    public static let physicalSizeUndetectable: PropID = "Physical Size can't be detected"
    public static let zerosTailIsAllowed: PropID  = "Zeros Tail Is Allowed" // IDS_PROP_ZEROS_TAIL_IS_ALLOWED
    public static let deleted: PropID             = "Deleted"               // IDS_PROP_DELETED
    public static let isTree: PropID              = "Is Tree"               // IDS_PROP_IS_TREE
    public static let aux: PropID                 = "Aux"                   // IDS_PROP_AUX
    public static let localName: PropID           = "Local Name"            // IDS_PROP_LOCAL_NAME
    public static let provider: PropID            = "Provider"              // IDS_PROP_PROVIDER
    public static let archiveFileName: PropID     = "ArcFileName"           // IDS_PROP_ARC_FILE_NAME
}

// MARK: - Value kinds (drives column formatting and sort order)

extension PropID {
    /// How a value for this property should be interpreted and rendered.
    ///
    /// The CLI engine hands every value across as a `String` (that is all `-slt`
    /// gives it); the column model uses this to decide alignment, sort comparator
    /// and formatter.
    public enum ValueKind: String, Sendable, Hashable, CaseIterable {
        /// Free-form text.
        case text
        /// A path inside the archive, `/`-separated. Sorted with the natural,
        /// numeric-aware comparator 7-Zip uses.
        case path
        /// A byte count. Right-aligned, byte-formatted.
        case byteCount
        /// A plain integer count or index. Right-aligned.
        case integer
        /// A `YYYY-MM-DD HH:MM:SS[.fffffffff]` timestamp.
        case timestamp
        /// A 7-Zip boolean, rendered `+` (true) / `-` (false) / empty (unknown).
        case boolean
        /// An uppercase hexadecimal CRC-32 or other checksum digest.
        case checksum
        /// A 7-Zip attribute string, e.g. `D drwxr-xr-x`.
        case attributes
    }

    /// The value kind for this property, defaulting to ``ValueKind/text`` for
    /// properties we do not have a specific rendering rule for.
    public var valueKind: ValueKind {
        Self.valueKinds[self] ?? .text
    }

    private static let valueKinds: [PropID: ValueKind] = [
        .path: .path, .name: .path, .outName: .path, .shortName: .path,
        .pathPrefix: .path, .localName: .path, .symbolicLink: .path,
        .hardLink: .path, .ntReparse: .path, .copyLink: .path,
        .archiveFileName: .path,

        .size: .byteCount, .packedSize: .byteCount, .physicalSize: .byteCount,
        .headersSize: .byteCount, .totalPhysicalSize: .byteCount,
        .virtualSize: .byteCount, .unpackSize: .byteCount, .tailSize: .byteCount,
        .embeddedStubSize: .byteCount, .totalSize: .byteCount,
        .freeSpace: .byteCount, .clusterSize: .byteCount, .sectorSize: .byteCount,
        .altStreamsSize: .byteCount, .dictionarySize: .byteCount,

        .created: .timestamp, .accessed: .timestamp, .modified: .timestamp,
        .metadataChanged: .timestamp,

        .isFolder: .boolean, .encrypted: .boolean, .commented: .boolean,
        .solid: .boolean, .anti: .boolean, .splitBefore: .boolean,
        .splitAfter: .boolean, .isVolume: .boolean, .readOnly: .boolean,
        .deleted: .boolean, .isTree: .boolean, .bit64: .boolean,
        .bigEndian: .boolean, .isHash: .boolean, .isNotArchiveType: .boolean,
        .physicalSizeUndetectable: .boolean, .zerosTailIsAllowed: .boolean,
        .altStream: .boolean, .aux: .boolean,

        .crc: .checksum, .checksum: .checksum, .sha1: .checksum, .sha256: .checksum,

        .attributes: .attributes,

        .block: .integer, .numBlocks: .integer, .position: .integer,
        .offset: .integer, .folders: .integer, .files: .integer,
        .links: .integer, .inode: .integer, .numVolumes: .integer,
        .volumeIndex: .integer, .numStreams: .integer, .numAltStreams: .integer,
        .numErrors: .integer, .streamID: .integer, .userID: .integer,
        .groupID: .integer, .deviceMajor: .integer, .deviceMinor: .integer,
        .devMajor: .integer, .devMinor: .integer, .codePage: .integer,
        .virtualAddress: .integer,
    ]
}

// MARK: - Well-known ordering

extension PropID {
    /// Every property 7-Zip is known to emit, in the declaration order of
    /// `PropertyName.rc`. Useful as a stable tie-breaker when building the
    /// column-picker menu for a format whose advertised order we do not know.
    public static let wellKnown: [PropID] = [
        .path, .name, .extensionName, .isFolder, .size, .packedSize, .attributes,
        .created, .accessed, .modified, .solid, .commented, .encrypted,
        .splitBefore, .splitAfter, .dictionarySize, .crc, .fileType, .anti,
        .method, .hostOS, .fileSystem, .user, .group, .block, .comment,
        .position, .pathPrefix, .folders, .files, .version, .volume, .isVolume,
        .offset, .links, .numBlocks, .numVolumes, .bit64, .bigEndian, .cpu,
        .physicalSize, .headersSize, .checksum, .characteristics, .virtualAddress,
        .identifier, .shortName, .creatorApplication, .sectorSize, .posixMode,
        .symbolicLink, .error, .totalSize, .freeSpace, .clusterSize, .volumeName,
        .localName, .provider, .ntSecurity, .altStream, .aux, .deleted, .isTree,
        .sha1, .sha256, .errorType, .numErrors, .warningFlags, .warning,
        .numStreams, .numAltStreams, .altStreamsSize, .virtualSize, .unpackSize,
        .totalPhysicalSize, .volumeIndex, .subType, .shortComment, .codePage,
        .isNotArchiveType, .physicalSizeUndetectable, .zerosTailIsAllowed,
        .tailSize, .embeddedStubSize, .ntReparse, .hardLink, .inode, .streamID,
        .readOnly, .outName, .copyLink, .archiveFileName, .isHash,
        .metadataChanged, .userID, .groupID, .deviceMajor, .deviceMinor,
        .devMajor, .devMinor,
    ]

    private static let wellKnownSet: Set<PropID> = Set(wellKnown)
}

extension PropID: CustomStringConvertible {
    public var description: String { rawValue }
}
