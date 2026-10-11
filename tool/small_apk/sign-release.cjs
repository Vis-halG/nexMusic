// Aligns and re-signs a recompressed APK with the existing release certificate.
// Credentials stay in child-process environment variables, never in arguments.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const [input, output] = process.argv.slice(2);
if (!input || !output) throw Error('Usage: node sign-release.cjs unsigned.apk output.apk');
const root = path.resolve(__dirname, '../..');
const properties = Object.fromEntries(fs.readFileSync(path.join(root, 'android/key.properties'), 'utf8')
  .split(/\r?\n/).filter(line => line.includes('=')).map(line => {
    const split = line.indexOf('='); return [line.slice(0, split).trim(), line.slice(split + 1).trim()];
  }));
for (const key of ['storeFile', 'storePassword', 'keyPassword', 'keyAlias']) {
  if (!properties[key]) throw Error(`Missing release signing property: ${key}`);
}
const keyFile = path.isAbsolute(properties.storeFile) ? properties.storeFile
  : path.resolve(root, 'android/app', properties.storeFile);
if (!fs.existsSync(keyFile)) throw Error('Release keystore not found; refusing to change the signing certificate.');
const sdk = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT || path.join(process.env.LOCALAPPDATA, 'Android/Sdk');
const versions = fs.readdirSync(path.join(sdk, 'build-tools')).filter(v => /^\d+\.\d+\.\d+$/.test(v))
  .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
if (!versions.length) throw Error('Android build tools not found.');
const tools = path.join(sdk, 'build-tools', versions.at(-1));
const suffix = process.platform === 'win32' ? '.exe' : '';
const java = process.env.JAVA_HOME ? path.join(process.env.JAVA_HOME, 'bin', `java${suffix}`) : `java${suffix}`;
const aligned = `${output}.aligned.apk`;
fs.mkdirSync(path.dirname(path.resolve(output)), { recursive: true });
execFileSync(path.join(tools, `zipalign${suffix}`), ['-f', '4', input, aligned], { stdio: 'inherit' });
const jar = path.join(tools, 'lib/apksigner.jar');
const env = { ...process.env, NEX_APK_STORE_PASSWORD: properties.storePassword, NEX_APK_KEY_PASSWORD: properties.keyPassword };
execFileSync(java, ['-jar', jar, 'sign', '--ks', keyFile, '--ks-key-alias', properties.keyAlias,
  '--ks-pass', 'env:NEX_APK_STORE_PASSWORD', '--key-pass', 'env:NEX_APK_KEY_PASSWORD',
  '--out', output, aligned], { env, stdio: 'inherit' });
execFileSync(java, ['-jar', jar, 'verify', '--verbose', output], { stdio: 'inherit' });
execFileSync(path.join(tools, `zipalign${suffix}`), ['-c', '4', output], { stdio: 'inherit' });
fs.unlinkSync(aligned);
console.log(`Signed universal APK: ${(fs.statSync(output).size / 1e6).toFixed(2)} MB`);
