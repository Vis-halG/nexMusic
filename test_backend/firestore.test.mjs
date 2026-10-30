import {readFile} from 'node:fs/promises';
import {after,before,beforeEach,test} from 'node:test';
import {initializeTestEnvironment,assertSucceeds,assertFails} from '@firebase/rules-unit-testing';
import {doc,setDoc,getDoc,getDocs,deleteDoc,collection,query,where,writeBatch,updateDoc,serverTimestamp,Timestamp,arrayUnion} from 'firebase/firestore';
let env;
before(async () => {env=await initializeTestEnvironment({projectId:'demo-nexmusic',firestore:{host:'127.0.0.1',port:8086,rules:await readFile(new URL('../firestore.rules',import.meta.url),'utf8')}});});
beforeEach(async () => env.clearFirestore());
after(async () => env?.cleanup());
const db = uid => env.authenticatedContext(uid).firestore();
const playlist = () => ({id:'playlist1',ownerUid:'owner',name:'Mix',cover:'🎧',description:'',public:false,deleted:false,updatedAt:Date.now(),tracks:[],members:['owner'],editors:['owner']});
async function seed() {await setDoc(doc(db('owner'),'playlists/playlist1'),playlist());}
async function join(uid,token,editor=false) {
  const client=db(uid),batch=writeBatch(client);
  batch.set(doc(client,`users/${uid}/playlistJoins/playlist1`),{inviteId:token,createdAt:serverTimestamp()});
  batch.update(doc(client,'playlists/playlist1'),{members:arrayUnion(uid),...(editor?{editors:arrayUnion(uid)}:{}),updatedAt:Date.now()});
  return batch.commit();
}
test('private activity and listening stats stay within the account',async () => {
  await assertSucceeds(setDoc(doc(db('alice'),'users/alice/activity/track'),{song:{id:'track'},liked:true,likedAt:1}));
  await assertFails(getDoc(doc(db('bob'),'users/alice/activity/track')));
  await assertFails(setDoc(doc(db('bob'),'users/alice/activity/track'),{song:{id:'track'}}));
});

test('presence is per-device and private; clients cannot spoof timestamps or change block state', async () => {
  const alice=db('alice'), bob=db('bob');
  const presence=doc(alice,'appPresence/alice');
  await assertSucceeds(setDoc(presence,{lastDeviceId:'phone1',sessions:{phone1:{signedIn:true,lastSeen:serverTimestamp()}}}));
  await assertSucceeds(setDoc(presence,{lastDeviceId:'phone2',sessions:{phone2:{signedIn:true,lastSeen:serverTimestamp()}}},{merge:true}));
  await assertSucceeds(setDoc(presence,{lastDeviceId:'phone1',sessions:{phone1:{signedIn:false,lastSeen:serverTimestamp()}}},{merge:true}));
  const sessions=(await getDoc(presence)).data().sessions;
  if (!sessions.phone2.signedIn || sessions.phone1.signedIn) throw Error('One phone must not sign out another');
  await assertFails(getDoc(doc(bob,'appPresence/alice')));
  await assertFails(setDoc(presence,{lastDeviceId:'phone1',sessions:{phone1:{signedIn:true,lastSeen:Timestamp.fromMillis(Date.now()+60000)}}},{merge:true}));
  await assertFails(setDoc(doc(alice,'appUsers/alice'),{blocked:false}));
});

test('a server block immediately denies shared and private data but permits reading own access status', async () => {
  const alice=db('alice');
  await setDoc(doc(alice,'users/alice/activity/song'),{song:{id:'song'},liked:true});
  await env.withSecurityRulesDisabled(async context => {
    await setDoc(doc(context.firestore(),'appUsers/alice'),{blocked:true,updatedAt:Date.now()});
    await setDoc(doc(context.firestore(),'globalMusic/song'),{song:{id:'song'},likes:1,plays:1});
  });
  await assertSucceeds(getDoc(doc(alice,'appUsers/alice')));
  await assertFails(getDoc(doc(alice,'globalMusic/song')));
  await assertFails(getDoc(doc(alice,'users/alice/activity/song')));
  await assertFails(setDoc(doc(alice,'appUsers/alice'),{blocked:false}));
  await assertFails(getDoc(doc(db('bob'),'appUsers/alice')));
});
test('playlist ownership cannot be forged or changed and private reads require membership',async () => {
  await seed(); await assertFails(getDoc(doc(db('bob'),'playlists/playlist1')));
  await assertFails(setDoc(doc(db('bob'),'playlists/fake'),{...playlist(),id:'fake'}));
  await assertFails(updateDoc(doc(db('owner'),'playlists/playlist1'),{ownerUid:'bob'}));
  await assertSucceeds(updateDoc(doc(db('owner'),'playlists/playlist1'),{public:true}));
  await assertSucceeds(getDoc(doc(db('bob'),'playlists/playlist1')));
});
test('valid invite joins a private playlist, editors can edit tracks, viewers cannot escalate',async () => {
  await seed(); const owner=db('owner');
  await setDoc(doc(owner,'playlistInvites/editor'),{playlistId:'playlist1',ownerUid:'owner',editor:true,createdAt:serverTimestamp(),expiresAt:Timestamp.fromMillis(Date.now()+3600000)});
  await assertSucceeds(join('bob','editor',true));
  await assertSucceeds(updateDoc(doc(db('bob'),'playlists/playlist1'),{tracks:[{id:'song',title:'Track'}],updatedAt:Date.now()}));
  await assertFails(updateDoc(doc(db('bob'),'playlists/playlist1'),{public:true}));
  await setDoc(doc(owner,'playlistInvites/viewer'),{playlistId:'playlist1',ownerUid:'owner',editor:false,createdAt:serverTimestamp(),expiresAt:Timestamp.fromMillis(Date.now()+3600000)});
  await assertFails(join('eve','viewer',true));
  await assertSucceeds(join('eve','viewer'));
  await assertFails(updateDoc(doc(db('eve'),'playlists/playlist1'),{name:'Hacked'}));
});
test('room guests can join/request/vote but cannot control host playback or alter another vote',async () => {
  const room=doc(db('host'),'listeningRooms/room1');
  await assertSucceeds(setDoc(room,{name:'Room',hostUid:'host',members:['host'],active:true,createdAt:serverTimestamp(),updatedAt:serverTimestamp(),current:null,playing:false,positionMs:0}));
  const guest=db('guest'); await assertSucceeds(updateDoc(doc(guest,'listeningRooms/room1'),{members:arrayUnion('guest')}));
  await assertFails(updateDoc(doc(guest,'listeningRooms/room1'),{playing:true}));
  await assertSucceeds(setDoc(doc(guest,'listeningRooms/room1/requests/request1'),{song:{id:'a',title:'Track'},requestedBy:'guest',votes:{},createdAt:serverTimestamp()}));
  await assertSucceeds(updateDoc(doc(guest,'listeningRooms/room1/requests/request1'),{'votes.guest':true}));
  await assertFails(updateDoc(doc(guest,'listeningRooms/room1/requests/request1'),{'votes.host':true}));
  await assertFails(getDoc(doc(db('stranger'),'listeningRooms/room1/requests/request1')));
});

test('public playlists never expose invite tokens; join proofs are private and revoked links fail',async () => {
  await seed();const owner=db('owner');
  await updateDoc(doc(owner,'playlists/playlist1'),{public:true});
  await setDoc(doc(owner,'playlistInvites/secret'),{playlistId:'playlist1',ownerUid:'owner',editor:true,createdAt:serverTimestamp(),expiresAt:Timestamp.fromMillis(Date.now()+3600000)});
  await assertSucceeds(join('bob','secret',true));
  const visible=(await assertSucceeds(getDoc(doc(db('outsider'),'playlists/playlist1')))).data();
  if ('joinToken' in visible || 'inviteId' in visible) throw Error('Public invitation token leak');
  await assertFails(getDoc(doc(db('outsider'),'users/bob/playlistJoins/playlist1')));
  await assertFails(updateDoc(doc(db('outsider'),'playlists/playlist1'),{members:arrayUnion('outsider'),editors:arrayUnion('outsider')}));
  await assertFails(getDocs(collection(db('outsider'),'playlistInvites')));
  await assertSucceeds(getDocs(query(collection(owner,'playlistInvites'),where('ownerUid','==','owner'))));
  await assertSucceeds(deleteDoc(doc(owner,'playlistInvites/secret')));
  await assertFails(join('outsider','secret',true));
});

test('anyone signed in can rename or delete any category, but not anonymously',async () => {
  await env.withSecurityRulesDisabled(async context => {
    await setDoc(doc(context.firestore(),'categories/rock'),{name:'Rock',ownerUid:'owner',createdAt:Timestamp.now()});
  });
  await assertSucceeds(updateDoc(doc(db('bob'),'categories/rock'),{name:'Classic rock'}));
  await assertFails(updateDoc(doc(db('bob'),'categories/rock'),{ownerUid:'bob'}));
  await assertFails(updateDoc(doc(db('bob'),'categories/rock'),{name:''}));
  await assertFails(deleteDoc(doc(env.unauthenticatedContext().firestore(),'categories/rock')));
  await assertSucceeds(deleteDoc(doc(db('bob'),'categories/rock')));
});

test('a song can list several categories, its main one included',async () => {
  await env.withSecurityRulesDisabled(async context => {
    const admin=context.firestore();
    await setDoc(doc(admin,'categories/pop'),{name:'Pop',ownerUid:'owner',createdAt:Timestamp.now()});
    await setDoc(doc(admin,'categories/rain'),{name:'Rain',ownerUid:'owner',createdAt:Timestamp.now()});
  });
  const song=(extra={}) => ({title:'Song',kind:'audio',categoryId:'pop',url:'https://res.cloudinary.com/demo/a.mp3',publicId:'a',sizeBytes:1000,durationMs:0,ownerUid:'alice',ownerName:'Alice',createdAt:serverTimestamp(),updatedAt:serverTimestamp(),deleted:false,...extra});
  const alice=db('alice'), bob=db('bob');
  // Older app versions write only the main category.
  await assertSucceeds(setDoc(doc(alice,'songs/old'),song()));
  await assertSucceeds(setDoc(doc(alice,'songs/both'),song({categoryIds:['pop','rain']})));
  await assertFails(setDoc(doc(alice,'songs/bad'),song({categoryIds:['rain']})));
  await assertFails(setDoc(doc(alice,'songs/empty'),song({categoryIds:[]})));
  await assertFails(setDoc(doc(alice,'songs/many'),song({categoryIds:['pop',...Array.from({length:20},(_, i) => `c${i}`)]})));
  await assertSucceeds(updateDoc(doc(bob,'songs/old'),{categoryId:'rain',categoryIds:['rain','pop'],updatedAt:serverTimestamp()}));
  await assertFails(updateDoc(doc(bob,'songs/old'),{categoryIds:['pop'],updatedAt:serverTimestamp()}));
  await assertSucceeds(updateDoc(doc(bob,'songs/both'),{title:'Renamed',updatedAt:serverTimestamp()}));
});

test('public Library accepts audio only, and legacy videos can be deleted but never restored', async () => {
  const song = {title:'Track',kind:'audio',categoryId:'pop',url:'https://res.cloudinary.com/demo/a.mp3',publicId:'a',sizeBytes:1000,durationMs:0,ownerUid:'alice',ownerName:'Alice',createdAt:serverTimestamp(),updatedAt:serverTimestamp(),deleted:false};
  await env.withSecurityRulesDisabled(async context => {
    const admin = context.firestore();
    await setDoc(doc(admin,'categories/pop'),{name:'Pop',ownerUid:'owner',createdAt:Timestamp.now()});
    await setDoc(doc(admin,'songs/legacy-video'),{...song,kind:'video'});
  });
  const alice = db('alice');
  await assertSucceeds(setDoc(doc(alice,'songs/audio'),song));
  await assertFails(setDoc(doc(alice,'songs/video'),{...song,kind:'video'}));
  await assertSucceeds(updateDoc(doc(alice,'songs/legacy-video'),{deleted:true,updatedAt:serverTimestamp()}));
  await assertFails(updateDoc(doc(alice,'songs/legacy-video'),{deleted:false,updatedAt:serverTimestamp()}));
});
