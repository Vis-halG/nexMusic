import fs from 'node:fs';
import path from 'node:path';

// ZIP inventory only. Expanded payload sizes are not Android's installed size.
function inventory(file) {
  const apk = fs.readFileSync(file);
  let end = -1;
  for (let offset = apk.length - 22; offset >= Math.max(0, apk.length - 65557); offset--) {
    if (apk.readUInt32LE(offset) === 0x06054b50) { end = offset; break; }
  }
  if (end < 0) throw new Error('Not an APK/ZIP file');
  let cursor = apk.readUInt32LE(end + 16);
  const count = apk.readUInt16LE(end + 10);
  const entries = [];
  for (let index = 0; index < count; index++) {
    if (apk.readUInt32LE(cursor) !== 0x02014b50) throw new Error('Invalid ZIP central directory');
    const nameLength = apk.readUInt16LE(cursor + 28);
    const extraLength = apk.readUInt16LE(cursor + 30);
    const commentLength = apk.readUInt16LE(cursor + 32);
    entries.push({
      name: apk.subarray(cursor + 46, cursor + 46 + nameLength).toString('utf8'),
      apkBytes: apk.readUInt32LE(cursor + 20),
      expandedBytes: apk.readUInt32LE(cursor + 24),
      compression: apk.readUInt16LE(cursor + 10),
    });
    cursor += 46 + nameLength + extraLength + commentLength;
  }
  const nativeBytesByAbi = {};
  for (const entry of entries) {
    const match = /^lib\/([^/]+)\/[^/]+\.so$/.exec(entry.name);
    if (match) nativeBytesByAbi[match[1]] = (nativeBytesByAbi[match[1]] ?? 0) + entry.expandedBytes;
  }
  return {
    file: path.resolve(file),
    apkBytes: apk.length,
    under10MbDownload: apk.length < 10000000,
    nativeBytesByAbi,
    expandedPayloadBytes: entries.reduce((sum, entry) => sum + entry.expandedBytes, 0),
    largestEntries: entries.sort((a, b) => b.expandedBytes - a.expandedBytes).slice(0, 15),
    note: 'Download size and expanded ZIP payload are not installed size. Compressed native libraries are extracted on install with useLegacyPackaging=true. Android also stores app code and may create compiled DEX files.',
  };
}

const [file, output] = process.argv.slice(2);
if (!file) throw new Error('Usage: node tool/apk_size_report.mjs path.apk [report.json]');
const report = inventory(file);
const json = JSON.stringify(report, null, 2);
if (output) fs.writeFileSync(output, json + '\n');
process.stdout.write(json + '\n');
