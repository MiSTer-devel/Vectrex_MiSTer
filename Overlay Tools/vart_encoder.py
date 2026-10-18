#!/usr/bin/env python3
"""Encode, verify, and decode VART artwork containers."""

from __future__ import annotations

from collections import deque
import math
from pathlib import Path
import struct
import zlib

from PIL import Image


MAGIC = b"VART"
VERSION = 1
HEADER_SIZE = 64
DESCRIPTOR_SIZE = 48
MAX_CONTAINER_BYTES = 4 * 1024 * 1024
ROW_ALIGNMENT = 8

ROLE_OVERLAY = 0
LEGACY_ROLE_NAMES = {
    ROLE_OVERLAY: "overlay",
    1: "foreground",
}

VECTREX_PLANES = {
    (1360, 1080),
    (916, 720),
    (720, 480),
    (720, 240),
}


class ArtworkError(RuntimeError):
    """A user-facing artwork validation or generation error."""


def align(value: int, alignment: int = ROW_ALIGNMENT) -> int:
    return (value + alignment - 1) & ~(alignment - 1)


class BitWriter:
    def __init__(self) -> None:
        self.data = bytearray()
        self.pending = 0
        self.pending_bits = 0
        self.bit_count = 0

    def write(self, value: int, width: int) -> None:
        if value < 0 or value >= (1 << width):
            raise ArtworkError(f"value {value} does not fit in {width} bits")
        self.pending |= value << self.pending_bits
        self.pending_bits += width
        self.bit_count += width
        while self.pending_bits >= 8:
            self.data.append(self.pending & 0xFF)
            self.pending >>= 8
            self.pending_bits -= 8

    def finish(self) -> tuple[bytes, int]:
        if self.pending_bits:
            self.data.append(self.pending & 0xFF)
        return bytes(self.data), self.bit_count


class BitReader:
    def __init__(self, data: bytes, bit_count: int) -> None:
        self.data = data
        self.bit_count = bit_count
        self.position = 0

    def read(self, width: int) -> int:
        end = self.position + width
        if width < 0 or end > self.bit_count:
            raise ArtworkError("compressed row ends inside a token")
        stop = (end + 7) >> 3
        if stop > len(self.data):
            raise ArtworkError("compressed row ends inside a token")
        value = int.from_bytes(self.data[self.position >> 3 : stop], "little")
        value >>= self.position & 7
        self.position = end
        return value & ((1 << width) - 1)


class RangeMinTree:
    """Incremental range-min tree used by the row packet optimizer."""

    def __init__(self, count: int) -> None:
        size = 1
        while size < count:
            size <<= 1
        self.size = size
        self.infinity = (1 << 60, 0, 0)
        self.values = [self.infinity] * (2 * size)

    def update(self, index: int, value: tuple[int, int, int]) -> None:
        position = self.size + index
        self.values[position] = value
        position >>= 1
        while position:
            self.values[position] = min(
                self.values[position << 1], self.values[(position << 1) | 1]
            )
            position >>= 1

    def query(self, start: int, stop: int) -> tuple[int, int, int]:
        """Return the minimum over the half-open interval [start, stop)."""
        if start >= stop:
            return self.infinity
        left = start + self.size
        right = stop + self.size
        result = self.infinity
        while left < right:
            if left & 1:
                result = min(result, self.values[left])
                left += 1
            if right & 1:
                right -= 1
                result = min(result, self.values[right])
            left >>= 1
            right >>= 1
        return result


def choose_packets(row: bytes, previous: bytes | None, bits: int) -> list[tuple[str, int]]:
    width = len(row)
    cost = [0] * (width + 1)
    choice: list[tuple[str, int] | None] = [None] * width
    literal_min: deque[tuple[int, int, int]] = deque()
    repeat_run = 0
    copy_run = 0

    for x in range(width - 1, -1, -1):
        # Endpoints arrive in descending order. Retain the lowest cost within
        # each packet window, preferring the farthest endpoint on equal cost.
        end = x + 1
        value = (cost[end] + bits * end, -end, end)
        while literal_min and value < literal_min[-1]:
            literal_min.pop()
        literal_min.append(value)
        while literal_min[0][2] > x + 128:
            literal_min.popleft()
        literal_end = literal_min[0][2]
        literal_len = literal_end - x
        literal_cost = 8 + bits * literal_len + cost[literal_end]
        best = (literal_cost, 2, -literal_len, "literal", literal_len)

        if x + 1 < width and row[x] == row[x + 1]:
            repeat_run = min(64, repeat_run + 1)
        else:
            repeat_run = 1
        if repeat_run >= 2:
            # Removing the first pixel of a legal suffix cannot increase its
            # cost: a two-pixel repeat becomes a one-pixel literal at equal
            # cost. Thus the longest repeat/copy also wins endpoint ties.
            repeat_len = repeat_run
            repeat_end = x + repeat_len
            candidate = (8 + bits + cost[repeat_end], 1, -repeat_len, "repeat", repeat_len)
            if candidate < best:
                best = candidate

        if previous is not None and row[x] == previous[x]:
            copy_run = min(64, copy_run + 1)
            copy_len = copy_run
            copy_end = x + copy_len
            candidate = (8 + cost[copy_end], 0, -copy_len, "copy", copy_len)
            if candidate < best:
                best = candidate
        else:
            copy_run = 0

        cost[x] = best[0]
        choice[x] = (best[3], best[4])

    packets: list[tuple[str, int]] = []
    x = 0
    while x < width:
        selected = choice[x]
        if selected is None:
            raise ArtworkError("packet optimizer did not cover the complete row")
        packets.append(selected)
        x += selected[1]
    return packets


def encode_row(row: bytes, previous: bytes | None, bits: int) -> tuple[bytes, int, int]:
    writer = BitWriter()
    x = 0
    packet_count = 0
    for operation, count in choose_packets(row, previous, bits):
        packet_count += 1
        if operation == "literal":
            writer.write(count - 1, 8)
            for index in row[x : x + count]:
                writer.write(index, bits)
        elif operation == "repeat":
            writer.write(0x80 | (count - 1), 8)
            writer.write(row[x], bits)
        elif operation == "copy":
            writer.write(0xC0 | (count - 1), 8)
        else:
            raise ArtworkError(f"unknown packet operation {operation}")
        x += count

    encoded, bit_count = writer.finish()
    if bit_count > 0xFFFF:
        raise ArtworkError(f"row requires {bit_count} encoded bits; maximum is 65535")
    record = bytearray(struct.pack("<H", bit_count))
    record.extend(encoded)
    record.extend(b"\x00" * (-len(record) % ROW_ALIGNMENT))
    return bytes(record), bit_count, packet_count


def decode_row(record: bytes, width: int, previous: bytes | None, bits: int) -> bytes:
    if len(record) < 2:
        raise ArtworkError("compressed row has no bit-count header")
    bit_count = struct.unpack_from("<H", record)[0]
    reader = BitReader(record[2:], bit_count)
    output = bytearray()

    while len(output) < width:
        header = reader.read(8)
        if not (header & 0x80):
            count = (header & 0x7F) + 1
            for _ in range(count):
                output.append(reader.read(bits))
        elif not (header & 0x40):
            count = (header & 0x3F) + 1
            output.extend([reader.read(bits)] * count)
        else:
            count = (header & 0x3F) + 1
            if previous is None:
                raise ArtworkError("first row contains a previous-row packet")
            start = len(output)
            output.extend(previous[start : start + count])

        if len(output) > width:
            raise ArtworkError("compressed row emits more pixels than its width")

    if reader.position != bit_count:
        raise ArtworkError(
            f"compressed row consumed {reader.position} of {bit_count} declared bits"
        )
    return bytes(output)


def load_indexed_rgba(path: Path) -> tuple[int, int, bytes, bytes, int, bool]:
    if not path.is_file():
        raise ArtworkError(f"{path}: file does not exist")
    if path.suffix.lower() != ".png":
        raise ArtworkError(f"{path}: artwork input must be a PNG")

    try:
        with Image.open(path) as source:
            if source.format != "PNG" or source.mode != "P":
                raise ArtworkError(
                    f"{path}: artwork must be an indexed PNG (P mode)"
                )

            width, height = source.size
            source_palette = source.getpalette()
            if source_palette is None or len(source_palette) < 3:
                raise ArtworkError(f"{path}: indexed PNG has no color palette")

            alpha = [255] * 256
            transparency = source.info.get("transparency")
            if isinstance(transparency, int):
                if not 0 <= transparency < 256:
                    raise ArtworkError(f"{path}: invalid transparent palette index")
                alpha[transparency] = 0
            elif isinstance(transparency, (bytes, bytearray, list, tuple)):
                if len(transparency) > 256:
                    raise ArtworkError(f"{path}: transparency table is too large")
                for index, value in enumerate(transparency):
                    alpha[index] = int(value)
            elif transparency is not None:
                raise ArtworkError(f"{path}: unsupported indexed transparency data")

            remap = bytearray(256)
            palette: list[tuple[int, int, int, int]] = []
            has_alpha = False

            source_pixels = source.tobytes()
            # Preserve first-use palette order while translating pixels in C.
            for source_index in dict.fromkeys(source_pixels):
                rgb_offset = source_index * 3
                if rgb_offset + 2 >= len(source_palette):
                    raise ArtworkError(
                        f"{path}: pixel uses missing palette index {source_index}"
                    )
                color = (
                    source_palette[rgb_offset],
                    source_palette[rgb_offset + 1],
                    source_palette[rgb_offset + 2],
                    alpha[source_index],
                )
                remap[source_index] = len(palette)
                palette.append(color)
                has_alpha |= color[3] != 255
            indices = source_pixels.translate(bytes(remap))
    except ArtworkError:
        raise
    except Exception as error:
        raise ArtworkError(f"{path}: cannot read PNG: {error}") from error

    color_count = len(palette)
    if color_count <= 16:
        bits = 4
    elif color_count <= 64:
        bits = 6
    else:
        bits = 8

    palette_entries = 1 << bits
    palette.extend([(0, 0, 0, 0)] * (palette_entries - len(palette)))
    palette_bytes = bytes(component for color in palette for component in color)
    return width, height, bytes(indices), palette_bytes, bits, has_alpha


def encode_plane(path: Path) -> dict[str, object]:
    width, height, pixels, palette, bits, has_alpha = load_indexed_rgba(path)
    return _encode_indexed_plane(width, height, pixels, palette, bits, has_alpha, path=path)


def _encode_indexed_plane(width: int, height: int, pixels: bytes, palette: bytes,
                          bits: int, has_alpha: bool, *, path: Path) -> dict[str, object]:
    """Encode validated indexed data, preserving its palette and index depth."""
    payload = bytearray()
    row_stats = []
    previous: bytes | None = None

    for y in range(height):
        row = pixels[y * width : (y + 1) * width]
        record, encoded_bits, packet_count = encode_row(row, previous, bits)
        decoded = decode_row(record, width, previous, bits)
        if decoded != row:
            raise ArtworkError(f"{path}: row {y} failed encoder round-trip")
        payload.extend(record)
        row_stats.append(
            {
                "y": y,
                "raw_bytes": math.ceil(width * bits / 8),
                "encoded_bits": encoded_bits,
                "encoded_bytes": math.ceil(encoded_bits / 8),
                "stored_bytes": len(record),
                "packets": packet_count,
            }
        )
        previous = row

    decoded_rows = []
    offset = 0
    previous = None
    for y in range(height):
        if offset + 2 > len(payload):
            raise ArtworkError(f"{path}: serialized payload ends before row {y}")
        encoded_bits = struct.unpack_from("<H", payload, offset)[0]
        record_size = align(2 + math.ceil(encoded_bits / 8))
        record = bytes(payload[offset : offset + record_size])
        decoded = decode_row(record, width, previous, bits)
        decoded_rows.append(decoded)
        previous = decoded
        offset += record_size

    if offset != len(payload) or b"".join(decoded_rows) != pixels:
        raise ArtworkError(f"{path}: complete payload failed exact round-trip")

    return {
        "role": ROLE_OVERLAY,
        "path": path,
        "width": width,
        "height": height,
        "pixels": pixels,
        "palette": palette,
        "palette_entries": 1 << bits,
        "bits": bits,
        "has_alpha": has_alpha,
        "payload": bytes(payload),
        "rows": row_stats,
        "raw_bytes": math.ceil(width * height * bits / 8),
    }


def build_container(planes: list[dict[str, object]]) -> bytes:
    validate_plane_set(planes)

    descriptor_offset = HEADER_SIZE
    cursor = align(HEADER_SIZE + DESCRIPTOR_SIZE * len(planes))
    palette_offsets: dict[bytes, int] = {}
    sections: list[tuple[int, bytes]] = []

    for plane in planes:
        palette = plane["palette"]
        assert isinstance(palette, bytes)
        if palette not in palette_offsets:
            palette_offsets[palette] = cursor
            sections.append((cursor, palette))
            cursor = align(cursor + len(palette))
        plane["palette_offset"] = palette_offsets[palette]

    for plane in planes:
        payload = plane["payload"]
        assert isinstance(payload, bytes)
        plane["payload_offset"] = cursor
        sections.append((cursor, payload))
        cursor = align(cursor + len(payload))

    total_size = cursor
    if total_size > MAX_CONTAINER_BYTES:
        raise ArtworkError(
            f"container is {total_size:,} bytes; maximum is {MAX_CONTAINER_BYTES:,}"
        )

    container = bytearray(total_size)
    header = struct.pack(
        "<4sBBBBIIIHHII32s",
        MAGIC,
        VERSION,
        0,
        1,
        len(planes),
        total_size,
        0,
        descriptor_offset,
        DESCRIPTOR_SIZE,
        0,
        0,
        0,
        b"\x00" * 32,
    )
    if len(header) != HEADER_SIZE:
        raise ArtworkError("internal error: VART header size is incorrect")
    container[:HEADER_SIZE] = header

    for index, plane in enumerate(planes):
        flags = 0x01
        if plane["has_alpha"]:
            flags |= 0x02
        descriptor = struct.pack(
            "<HHBBBBHHIIIIIIIII",
            int(plane["width"]),
            int(plane["height"]),
            ROLE_OVERLAY,
            ROLE_OVERLAY,
            int(plane["bits"]),
            flags,
            int(plane["palette_entries"]),
            0,
            int(plane["palette_offset"]),
            len(plane["palette"]),
            int(plane["payload_offset"]),
            len(plane["payload"]),
            int(plane["width"]) * int(plane["height"]),
            int(plane["height"]),
            0,
            0,
            0,
        )
        if len(descriptor) != DESCRIPTOR_SIZE:
            raise ArtworkError("internal error: VART descriptor size is incorrect")
        start = descriptor_offset + index * DESCRIPTOR_SIZE
        container[start : start + DESCRIPTOR_SIZE] = descriptor

    for offset, data in sections:
        container[offset : offset + len(data)] = data

    checksum = zlib.crc32(container[descriptor_offset:]) & 0xFFFFFFFF
    struct.pack_into("<I", container, 0x0C, checksum)
    return bytes(container)


def verify_container(
    container: bytes, planes: list[dict[str, object]], *, return_decoded: bool = False
) -> list[dict[str, object]] | None:
    """Check the serialized container against its encoder inputs."""
    validate_plane_set(planes)
    decoded = _decode_container(container, planes)
    return decoded if return_decoded else None


def decode_container(container: bytes) -> list[dict[str, object]]:
    """Validate and decode a VART v1 container into RGBA plane images."""
    return _decode_container(container)


def _decode_container(
    container: bytes, expected: list[dict[str, object]] | None = None
) -> list[dict[str, object]]:
    if len(container) < HEADER_SIZE:
        raise ArtworkError("VART container is shorter than its header")

    (
        magic,
        version,
        flags,
        layer_count,
        plane_count,
        total_size,
        checksum,
        descriptor_offset,
        descriptor_size,
        reserved16,
        reserved0,
        reserved1,
        reserved_bytes,
    ) = struct.unpack_from("<4sBBBBIIIHHII32s", container)

    if magic != MAGIC or version != VERSION:
        raise ArtworkError("unsupported VART container")
    if total_size != len(container) or total_size > MAX_CONTAINER_BYTES:
        raise ArtworkError("VART container size is invalid")
    if flags or reserved16 or reserved0 or reserved1 or any(reserved_bytes):
        raise ArtworkError("VART header has non-zero reserved fields")
    if not 1 <= layer_count <= 2 or not 1 <= plane_count <= 255:
        raise ArtworkError("VART layer or plane count is invalid")
    if expected is not None and (layer_count != 1 or plane_count != len(expected)):
        raise ArtworkError("generated VART layer or plane count failed verification")
    if descriptor_offset != HEADER_SIZE or descriptor_size != DESCRIPTOR_SIZE:
        raise ArtworkError("VART descriptor table layout is unsupported")
    if descriptor_offset + plane_count * descriptor_size > total_size:
        raise ArtworkError("VART descriptor table is out of range")
    if zlib.crc32(container[descriptor_offset:]) & 0xFFFFFFFF != checksum:
        raise ArtworkError("VART checksum is invalid")

    decoded_planes: list[dict[str, object]] = []
    for index in range(plane_count):
        start = descriptor_offset + index * descriptor_size
        fields = struct.unpack_from("<HHBBBBHHIIIIIIIII", container, start)
        width, height, layer_id, role, bits, desc_flags = fields[:6]
        palette_entries, descriptor_reserved = fields[6:8]
        palette_offset, palette_size, payload_offset, payload_size = fields[8:12]
        pixel_count, row_count, layout, reserved_a, reserved_b = fields[12:17]

        if expected is not None:
            source = expected[index]
            if (width, height, role, bits) != (
                source["width"], source["height"], source["role"], source["bits"]
            ):
                raise ArtworkError(f"generated descriptor {index} does not match its source")
            if layer_id != role:
                raise ArtworkError(f"generated descriptor {index} has invalid layer metadata")
            if palette_entries != source["palette_entries"]:
                raise ArtworkError(f"generated descriptor {index} has invalid palette size")
            if payload_offset < HEADER_SIZE or not payload_size:
                raise ArtworkError(f"generated payload {index} has an invalid range")

        if not width or not height or role not in LEGACY_ROLE_NAMES:
            raise ArtworkError(f"descriptor {index} has invalid plane metadata")
        if bits not in (4, 6, 8) or desc_flags & 0xFC or not desc_flags & 0x01:
            raise ArtworkError(f"descriptor {index} has unsupported index metadata")
        if descriptor_reserved or layout or reserved_a or reserved_b:
            raise ArtworkError(f"descriptor {index} has non-zero reserved fields")
        if palette_entries != 1 << bits or palette_size != palette_entries * 4:
            raise ArtworkError(f"descriptor {index} has invalid palette metadata")
        if pixel_count != width * height or row_count != height:
            raise ArtworkError(f"descriptor {index} has invalid dimensions")
        if palette_offset % ROW_ALIGNMENT or payload_offset % ROW_ALIGNMENT:
            raise ArtworkError(f"descriptor {index} is not qword aligned")
        if palette_offset + palette_size > total_size:
            raise ArtworkError(f"descriptor {index} palette is out of range")
        if payload_offset + payload_size > total_size:
            raise ArtworkError(f"descriptor {index} payload is out of range")

        palette = container[palette_offset : palette_offset + palette_size]
        if expected is not None and palette != expected[index]["palette"]:
            raise ArtworkError(f"generated palette {index} does not match its source")
        payload = container[payload_offset : payload_offset + payload_size]
        rows: list[bytes] = []
        previous = None
        offset = 0
        for y in range(height):
            if offset + 2 > len(payload):
                raise ArtworkError(f"descriptor {index} ends before row {y}")
            encoded_bits = struct.unpack_from("<H", payload, offset)[0]
            record_size = align(2 + math.ceil(encoded_bits / 8))
            if offset + record_size > len(payload):
                raise ArtworkError(f"descriptor {index} row {y} is truncated")
            record = payload[offset : offset + record_size]
            row = decode_row(record, width, previous, bits)
            rows.append(row)
            previous = row
            offset += record_size
        if offset != payload_size:
            raise ArtworkError(f"descriptor {index} has trailing payload data")

        indices = b"".join(rows)
        if expected is not None and indices != expected[index]["pixels"]:
            raise ArtworkError(f"generated payload {index} failed serialized round-trip")
        image = Image.frombytes("P", (width, height), indices)
        image.putpalette(palette, rawmode="RGBA")

        decoded_planes.append(
            {
                "index": index,
                "layer_id": layer_id,
                "role": role,
                "width": width,
                "height": height,
                "bits": bits,
                "has_alpha": bool(desc_flags & 0x02),
                "image": image.convert("RGBA"),
            }
        )

    return decoded_planes


def validate_plane_set(planes: list[dict[str, object]]) -> None:
    if len(planes) != 4:
        raise ArtworkError("Vectrex artwork requires exactly four overlay planes")
    if any(int(plane["role"]) != ROLE_OVERLAY for plane in planes):
        raise ArtworkError("Vectrex artwork supports only the overlay layer")

    actual = {
        (int(plane["width"]), int(plane["height"]))
        for plane in planes
    }
    if actual != VECTREX_PLANES:
        missing = sorted(VECTREX_PLANES - actual)
        extra = sorted(actual - VECTREX_PLANES)
        details = []
        if missing:
            details.append("missing " + ", ".join(f"{w}x{h}" for w, h in missing))
        if extra:
            details.append("unsupported " + ", ".join(f"{w}x{h}" for w, h in extra))
        raise ArtworkError("invalid Vectrex plane set: " + "; ".join(details))
