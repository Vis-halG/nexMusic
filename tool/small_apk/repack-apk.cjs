// Rewrites an APK with zopfli deflate, which packs the same files about 4%
// smaller than the Android build does. Uncompressed data, names and order stay
// the same, and stored entries (resources.arsc) stay stored. The output is
// unsigned and unaligned: build.ps1 runs zipalign and apksigner on it.
//
//   node repack-apk.cjs in.apk out-unsigned.apk [iterations]
const fs = require('fs');
const zlib = require('zlib');
const { deflateAsync } = require('@gfx/zopfli');

const [input, output, iterationsArg] = process.argv.slice(2);
const iterations = Number(iterationsArg ?? 15);
const apk = fs.readFileSync(input);

function findEndOfCentralDirectory(buffer) {
  for (let i = buffer.length - 22; i >= Math.max(0, buffer.length - 65557); i--) {
    if (buffer.readUInt32LE(i) === 0x06054b50) return i;
  }
  throw new Error('Not a zip file: end of central directory not found');
}

(async () => {
  const eocd = findEndOfCentralDirectory(apk);
  const count = apk.readUInt16LE(eocd + 10);
  let cursor = apk.readUInt32LE(eocd + 16);
  const parts = [];
  const central = [];
  let offset = 0;
  let before = 0;
  let after = 0;

  for (let i = 0; i < count; i++) {
    if (apk.readUInt32LE(cursor) !== 0x02014b50) throw new Error('Bad central directory');
    const madeBy = apk.readUInt16LE(cursor + 4);
    const needed = apk.readUInt16LE(cursor + 6);
    const flags = apk.readUInt16LE(cursor + 8) & ~0x0008; // no data descriptor
    const method = apk.readUInt16LE(cursor + 10);
    const time = apk.readUInt16LE(cursor + 12);
    const date = apk.readUInt16LE(cursor + 14);
    const crc = apk.readUInt32LE(cursor + 16);
    const compressedSize = apk.readUInt32LE(cursor + 20);
    const size = apk.readUInt32LE(cursor + 24);
    const nameLength = apk.readUInt16LE(cursor + 28);
    const extraLength = apk.readUInt16LE(cursor + 30);
    const commentLength = apk.readUInt16LE(cursor + 32);
    const internalAttributes = apk.readUInt16LE(cursor + 36);
    const externalAttributes = apk.readUInt32LE(cursor + 38);
    const localOffset = apk.readUInt32LE(cursor + 42);
    const name = apk.subarray(cursor + 46, cursor + 46 + nameLength);
    cursor += 46 + nameLength + extraLength + commentLength;

    if (apk.readUInt32LE(localOffset) !== 0x04034b50) throw new Error(`Bad local header: ${name}`);
    const dataStart =
      localOffset + 30 + apk.readUInt16LE(localOffset + 26) + apk.readUInt16LE(localOffset + 28);
    let data = apk.subarray(dataStart, dataStart + compressedSize);

    if (method === 8) {
      const raw = zlib.inflateRawSync(data);
      if (raw.length !== size || zlib.crc32(raw) !== crc) throw new Error(`CRC mismatch: ${name}`);
      if (size > 1000000) console.log(`Compressing ${name} (${Math.round(size / 1e6)} MB)`);
      const smaller = iterations > 0
        ? Buffer.from(await deflateAsync(raw, { numiterations: iterations }))
        : zlib.deflateRawSync(raw, { level: 9 });
      if (smaller.length < data.length) data = smaller;
    } else if (method !== 0) {
      throw new Error(`Unsupported compression method ${method}: ${name}`);
    }
    before += compressedSize;
    after += data.length;

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(needed, 4);
    local.writeUInt16LE(flags, 6);
    local.writeUInt16LE(method, 8);
    local.writeUInt16LE(time, 10);
    local.writeUInt16LE(date, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(size, 22);
    local.writeUInt16LE(nameLength, 26);
    local.writeUInt16LE(0, 28);
    parts.push(local, name, data);

    const entry = Buffer.alloc(46);
    entry.writeUInt32LE(0x02014b50, 0);
    entry.writeUInt16LE(madeBy, 4);
    entry.writeUInt16LE(needed, 6);
    entry.writeUInt16LE(flags, 8);
    entry.writeUInt16LE(method, 10);
    entry.writeUInt16LE(time, 12);
    entry.writeUInt16LE(date, 14);
    entry.writeUInt32LE(crc, 16);
    entry.writeUInt32LE(data.length, 20);
    entry.writeUInt32LE(size, 24);
    entry.writeUInt16LE(nameLength, 28);
    entry.writeUInt16LE(0, 30);
    entry.writeUInt16LE(0, 32);
    entry.writeUInt16LE(0, 34);
    entry.writeUInt16LE(internalAttributes, 36);
    entry.writeUInt32LE(externalAttributes, 38);
    entry.writeUInt32LE(offset, 42);
    central.push(entry, name);

    offset += local.length + name.length + data.length;
  }

  const centralSize = central.reduce((sum, part) => sum + part.length, 0);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(count, 8);
  end.writeUInt16LE(count, 10);
  end.writeUInt32LE(centralSize, 12);
  end.writeUInt32LE(offset, 16);
  fs.writeFileSync(output, Buffer.concat([...parts, ...central, end]));
  console.log(
    `${count} entries, compressed data ${before} -> ${after} bytes (saved ${Math.round((before - after) / 1024)} KB)`,
  );
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
