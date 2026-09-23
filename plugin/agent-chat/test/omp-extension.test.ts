import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import extension from '../adapters/omp/extension.ts';

test('queued native events follow registration and preserve increasing sequence', {timeout:5000}, async () => {
 const dir=await mkdtemp(join(tmpdir(),'chat-reconnect-'));
 const socketPath=join(dir,'broker.sock');
 const old=process.env.HEELER_CHAT_SOCKET;
 process.env.HEELER_CHAT_SOCKET=socketPath;
 const handlers=new Map();
 const ctx={sessionManager:{getSessionId:()=> 'test-session',getLeafId:()=>null,getEntry:()=>undefined},abort(){}};
 const observed=Promise.withResolvers();
 let peer;
 const frames=[];
 const server=net.createServer(socket=>{
  peer=socket;let buffer='';socket.setEncoding('utf8');
  socket.on('data',chunk=>{
   buffer+=chunk;
   for(;;){const end=buffer.indexOf('\n');if(end<0)break;
    const frame=JSON.parse(buffer.slice(0,end));buffer=buffer.slice(end+1);frames.push(frame);
    if(frames.length===1)socket.write(JSON.stringify({type:'welcome',protocol:1,maxFrameBytes:1048576})+'\n');
    if(frames.length===2){
     if(frame.type!=='register'){observed.resolve();return;}
     socket.write(JSON.stringify({type:'registered'})+'\n');
    }
    if(frame.event?.type==='resync_required')observed.resolve();
   }
  });
 });
 try {
  server.listen(socketPath);await once(server,'listening');
  extension({on:(name,fn)=>handlers.set(name,fn),sendUserMessage(){},getCommands:()=>[]});
  handlers.get('session_start')({},ctx);
 // Public events can arrive before the asynchronous socket handshake completes.
 // message_start is the per-turn event generator: turn lifecycle emits
 // message.* + history.changed, NOT session.changed (which is reserved for
 // real generation churn and triggers a client resync).
 for(let i=0;i<600;i++)handlers.get('message_start')({message:{role:'assistant'}},ctx);
  await observed.promise;
  assert.equal(frames[0].type,'hello');assert.equal(frames[1].type,'register');
  const events=frames.filter(f=>f.type==='event');
  assert.ok(events[0].seq>0,'first event must be newer than an empty snapshot watermark');
  assert.ok(events.some(f=>f.event.type==='resync_required'),'overflow must demand a new snapshot');
  for(let i=1;i<events.length;i++)assert.ok(events[i].seq>events[i-1].seq,'broker requires increasing producer sequence');
 } finally {
  handlers.get('session_shutdown')?.({},ctx);peer?.destroy();
  const closed=Promise.withResolvers();server.close(closed.resolve);await closed.promise;
  if(old===undefined)delete process.env.HEELER_CHAT_SOCKET;else process.env.HEELER_CHAT_SOCKET=old;
  await rm(dir,{recursive:true,force:true});
 }
});

test('no session.changed on per-turn activity; only on real generation churn', {timeout:5000}, async () => {
 const dir=await mkdtemp(join(tmpdir(),'chat-session-changed-'));
 const socketPath=join(dir,'broker.sock');
 const old=process.env.HEELER_CHAT_SOCKET;
 process.env.HEELER_CHAT_SOCKET=socketPath;
 const handlers=new Map();
 const sent=[];
 const ctx={sessionManager:{getSessionId:()=> 'test-session',getLeafId:()=>null,getEntry:()=>undefined},abort(){}};
 // Raw tap: answer every connection's handshake (bumpGeneration reregisters
 // on a FRESH socket, so ack register per connection).
 const frames=[];
 let conns=0;
 const server=net.createServer(socket=>{
  const conn=++conns;let buffer='';let seen=0;socket.setEncoding('utf8');
  socket.on('data',chunk=>{
   buffer+=chunk;
   for(;;){const end=buffer.indexOf('\n');if(end<0)break;
    const frame=JSON.parse(buffer.slice(0,end));buffer=buffer.slice(end+1);
    seen++;frames.push({conn,...frame});
    if(seen===1)socket.write(JSON.stringify({type:'welcome',protocol:1,maxFrameBytes:1048576})+'\n');
    if(frame.type==='register')socket.write(JSON.stringify({type:'registered'})+'\n');
    if(frame.type==='request'&&frame.method==='prompt.send'){
     sent.push(frame.params?.text);
     socket.write(JSON.stringify({type:'response',id:frame.id,result:{accepted:true,requestKey:frame.params?.requestKey}})+'\n');
    }
   }
  });
 });
 try {
  server.listen(socketPath);await once(server,'listening');
  extension({on:(name,fn)=>handlers.set(name,fn),sendUserMessage(t){},getCommands:()=>[]});
  handlers.get('session_start')({},ctx);
  await new Promise(r=>setTimeout(r,300)); // register lands
  // A full ordinary turn: the turn lifecycle must NOT emit session.changed
  // (the client maps that to a destructive full resync).
  handlers.get('agent_start')({},ctx);
  handlers.get('message_start')({message:{role:'assistant'}},ctx);
  handlers.get('message_update')({delta:'hi'});
  handlers.get('message_end')({message:{role:'assistant'}},ctx);
  handlers.get('turn_end')();
  await new Promise(r=>setTimeout(r,300));
  // Real generation churn: session.changed IS emitted, with its payload.
  handlers.get('session_switch')({},ctx);
  await new Promise(r=>setTimeout(r,500));
  handlers.get('session_shutdown')?.({},ctx);
  const changed=frames.filter(f=>f.type==='event'&&f.event.type==='session.changed');
  assert.equal(changed.length,1,'exactly one session.changed (generation churn only)');
  assert.equal(changed[0].event.reason,'session_switch');
  assert.equal(changed[0].event.sessionId,'test-session');
  assert.equal(changed[0].event.generation,2);
  assert.equal(changed[0].conn,2,'emitted on the reregistered generation-2 socket');
  assert.ok(frames.some(f=>f.type==='event'&&f.event.type==='message.started'),'turn lifecycle still streams');
  assert.ok(frames.some(f=>f.type==='event'&&f.event.type==='history.changed'),'history.changed still emitted');
 } finally {
  handlers.get('session_shutdown')?.({},ctx);
  const closed=Promise.withResolvers();server.close(closed.resolve);await closed.promise;
  if(old===undefined)delete process.env.HEELER_CHAT_SOCKET;else process.env.HEELER_CHAT_SOCKET=old;
  await rm(dir,{recursive:true,force:true});
 }
});

// Structured image send (attachments): prompt.send gains an OPTIONAL images
// array [{ref?,mimeType,byteLength?,data?}]. Text-only sends must stay the
// exact string call; image sends must reach pi.sendUserMessage as a CONTENT
// ARRAY (text block + image blocks), resolvable from inline base64 or the
// session blob store (img: refs).
test('prompt.send: text-only stays a string; images build a content array', {timeout:5000}, async () => {
 const dir=await mkdtemp(join(tmpdir(),'chat-image-send-'));
 const socketPath=join(dir,'broker.sock');
 const old=process.env.HEELER_CHAT_SOCKET;
 process.env.HEELER_CHAT_SOCKET=socketPath;
 const handlers=new Map();
 // Tiny real PNG (1x1 transparent): omp's image validator decodes the data.
 const pngB64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
 const calls=[];
 // Blob store: one stored user entry whose content array holds the image,
 // addressable as the img:<entryId>:c:<index> ref blob.read serves.
 const entryId='entry-1';
 const entries=new Map([[entryId,{id:entryId,parentId:null,type:'message',message:{role:'user',content:[{type:'text',text:'see attached'},{type:'image',data:pngB64,mimeType:'image/png'}]}}]]);
 const ctx={sessionManager:{getSessionId:()=>'test-session',getLeafId:()=>entryId,getEntry:id=>entries.get(id)},abort(){}};
 let conn;
 const connected=Promise.withResolvers();
 // Gate on the adapter's own register frame arriving at the server (the
 // 'registered' ack unblocks request serving on the adapter side).
 const registered=Promise.withResolvers();
 // The ADAPTER answers prompt.send requests itself over this socket; the
 // server only performs the handshake (welcome + registered acks).
 const server=net.createServer(socket=>{
  conn=socket;connected.resolve();let buffer='';socket.setEncoding('utf8');
  socket.on('data',chunk=>{
   buffer+=chunk;
   for(;;){const end=buffer.indexOf('\n');if(end<0)break;
    const frame=JSON.parse(buffer.slice(0,end));buffer=buffer.slice(end+1);
    if(frame.type==='hello')socket.write(JSON.stringify({type:'welcome',protocol:1,maxFrameBytes:1048576})+'\n');
    if(frame.type==='register'){socket.write(JSON.stringify({type:'registered'})+'\n');registered.resolve();}
   }
  });
 });
 const request=(params)=>{
  const {promise,resolve}=Promise.withResolvers();
  const id='req-'+Math.random().toString(36).slice(2);
  let buf='';
  const onData=chunk=>{
   buf+=chunk;
   for(;;){const end=buf.indexOf('\n');if(end<0)break;
    const frame=JSON.parse(buf.slice(0,end));buf=buf.slice(end+1);
    if(frame.type==='response'&&frame.id===id){conn.off('data',onData);resolve(frame);}
   }
  };
  conn.on('data',onData);
  conn.write(JSON.stringify({type:'request',id,method:'prompt.send',params})+'\n');
  return promise;
 };
 try {
  server.listen(socketPath);await once(server,'listening');
  extension({on:(name,fn)=>handlers.set(name,fn),sendUserMessage(c){calls.push(c);},getCommands:()=>[]});
  handlers.get('session_start')({},ctx);
  await registered.promise;
  // 1) text-only: EXACT string, no array.
  const r1=await request({text:'plain hello',requestKey:'k1'});
  assert.equal(r1.result?.accepted,true);
  assert.equal(calls.at(-1),'plain hello');
  // 2) inline base64 image: content ARRAY with text + image blocks.
  const r2=await request({text:'what is this?',requestKey:'k2',images:[{data:pngB64,mimeType:'image/png'}]});
  assert.equal(r2.result?.accepted,true);
  const c2=calls.at(-1);
  assert.ok(Array.isArray(c2),'image send must pass a content array');
  assert.deepEqual(c2,[{type:'text',text:'what is this?'},{type:'image',data:pngB64,mimeType:'image/png'}]);
  // 3) blob-store ref: resolves to the SAME bytes as blob.read serves.
  const r3=await request({text:'look at this ref',requestKey:'k3',images:[{ref:`img:${entryId}:c:1`,mimeType:'image/png'}]});
  assert.equal(r3.result?.accepted,true);
  const c3=calls.at(-1);
  assert.ok(Array.isArray(c3));
  assert.deepEqual(c3,[{type:'text',text:'look at this ref'},{type:'image',data:pngB64,mimeType:'image/png'}]);
  // 3b) IMAGE-ONLY draft: empty text + nonempty images is ACCEPTED and
  // delivers an EMPTY text block + the image (no filler text fabricated).
  const r3b=await request({text:'',requestKey:'k3b',images:[{data:pngB64,mimeType:'image/png'}]});
  assert.equal(r3b.result?.accepted,true,'image-only send must be accepted');
  const c3b=calls.at(-1);
  assert.ok(Array.isArray(c3b));
  assert.deepEqual(c3b,[{type:'text',text:''},{type:'image',data:pngB64,mimeType:'image/png'}]);
  // 4) validations reject (nothing sent on): bad mime, both data+ref, unknown ref.
  const bad=[
   {code:'invalid_request',params:{text:'x',requestKey:'e1',images:[{data:pngB64,mimeType:'image/bmp'}]}},
   {code:'invalid_request',params:{text:'x',requestKey:'e2',images:[{data:pngB64,ref:`img:${entryId}:c:1`,mimeType:'image/png'}]}},
   // Unknown blob ref: the blob store's own contract code, not invalid_request.
   {code:'item_not_found',params:{text:'x',requestKey:'e3',images:[{ref:'img:missing:c:0',mimeType:'image/png'}]}},
   {code:'invalid_request',params:{text:'x',requestKey:'e4',images:[]}},
   // Genuinely empty submission: no text AND no images.
   {code:'invalid_request',params:{text:'',requestKey:'e5'}},
  ];
  for(const {code,params} of bad){
   const r=await request(params);
   assert.equal(r.error?.code,code,JSON.stringify(params));
   assert.equal(calls.length,4,'no send after a rejected prompt');
  }
 } finally {
  handlers.get('session_shutdown')?.({},ctx);
  const closed=Promise.withResolvers();server.close(closed.resolve);await closed.promise;
  if(old===undefined)delete process.env.HEELER_CHAT_SOCKET;else process.env.HEELER_CHAT_SOCKET=old;
  await rm(dir,{recursive:true,force:true});
 }
});

test('registration declares attachments capability', {timeout:5000}, async () => {
 const dir=await mkdtemp(join(tmpdir(),'chat-image-cap-'));
 const socketPath=join(dir,'broker.sock');
 const old=process.env.HEELER_CHAT_SOCKET;
 process.env.HEELER_CHAT_SOCKET=socketPath;
 const handlers=new Map();
 const ctx={sessionManager:{getSessionId:()=> 'test-session',getLeafId:()=>null,getEntry:()=>undefined},abort(){}};
 let peer;let register;
 const server=net.createServer(socket=>{
  peer=socket;let buffer='';socket.setEncoding('utf8');
  socket.on('data',chunk=>{
   buffer+=chunk;
   for(;;){const end=buffer.indexOf('\n');if(end<0)break;
    const frame=JSON.parse(buffer.slice(0,end));buffer=buffer.slice(end+1);
    if(frame.type==='hello')socket.write(JSON.stringify({type:'welcome',protocol:1,maxFrameBytes:1048576})+'\n');
    if(frame.type==='register'){register=frame;socket.write(JSON.stringify({type:'registered'})+'\n');}
   }
  });
 });
 try {
  server.listen(socketPath);await once(server,'listening');
  extension({on:(name,fn)=>handlers.set(name,fn),sendUserMessage(){},getCommands:()=>[]});
  handlers.get('session_start')({},ctx);
  await new Promise(r=>setTimeout(r,300));
  assert.equal(register?.registration?.capabilities?.attachments,true,'attachments capability must be declared once the image-send path exists');
 } finally {
  handlers.get('session_shutdown')?.({},ctx);peer?.destroy();
  const closed=Promise.withResolvers();server.close(closed.resolve);await closed.promise;
  if(old===undefined)delete process.env.HEELER_CHAT_SOCKET;else process.env.HEELER_CHAT_SOCKET=old;
  await rm(dir,{recursive:true,force:true});
 }
});

// Pane ownership: ONLY the pane's primary agent claims HERDR_PANE_ID in its
// registration. An omp task-subagent (session file nested INSIDE the parent
// session's .jsonl directory) inherits the pane env var but must NOT claim
// the parent pane — duplicate live pane claims make the app's matcher
// correctly refuse (ambiguous).
test('registration pane claim: primary agent claims the pane; subagents do not', {timeout:5000}, async () => {
 const dir=await mkdtemp(join(tmpdir(),'chat-pane-claim-'));
 const socketPath=join(dir,'broker.sock');
 const oldSocket=process.env.HEELER_CHAT_SOCKET;
 const oldPane=process.env.HERDR_PANE_ID;
 process.env.HEELER_CHAT_SOCKET=socketPath;
 process.env.HERDR_PANE_ID='w9:pZ';
 const handlers=new Map();
 const registers=[];
 // One ctx per (fake) agent; getSessionFile feeds subagent detection.
 const ctxFor=(sessionFile)=>({sessionManager:{getSessionId:()=> 'sess-'+registers.length,getLeafId:()=>null,getEntry:()=>undefined,getSessionFile:()=>sessionFile},abort(){}});
 const server=net.createServer(socket=>{
  socket.setEncoding('utf8');let buffer='';
  socket.on('data',chunk=>{
   buffer+=chunk;
   for(;;){const end=buffer.indexOf('\n');if(end<0)break;
    const frame=JSON.parse(buffer.slice(0,end));buffer=buffer.slice(end+1);
    if(frame.type==='hello')socket.write(JSON.stringify({type:'welcome',protocol:1,maxFrameBytes:1048576})+'\n');
    if(frame.type==='register'){registers.push(frame.registration);socket.write(JSON.stringify({type:'registered'})+'\n');}
   }
  });
 });
 // Per-adapter handler maps keyed by EVENT NAME (one map per agent, exactly
 // how omp dispatches); a single shared map would let later on() calls
 // overwrite earlier events' handlers. Declared before try so the finally
 // can shut both adapters down.
 const hPrimary=new Map(); const hSub=new Map();
 try {
  server.listen(socketPath);await once(server,'listening');
  extension({on:(name,fn)=>hPrimary.set(name,fn),sendUserMessage(){},getCommands:()=>[]});
  hPrimary.get('session_start')({},ctxFor('/sessions/2026-01-01_primary.jsonl'));
  extension({on:(name,fn)=>hSub.set(name,fn),sendUserMessage(){},getCommands:()=>[]});
  hSub.get('session_start')({},ctxFor('/sessions/2026-01-01_primary.jsonl/TaskSub.jsonl'));
  await new Promise(r=>setTimeout(r,400));
  assert.equal(registers.length,2,'both the primary and the subagent register');
  const bySession=Object.fromEntries(registers.map(r=>[r.locator?.sessionFile,r]));
  assert.equal(bySession['/sessions/2026-01-01_primary.jsonl']?.locator?.paneId,'w9:pZ','primary agent claims its pane');
  assert.equal(bySession['/sessions/2026-01-01_primary.jsonl/TaskSub.jsonl']?.locator?.paneId,undefined,'subagent must NOT claim the parent pane');
  assert.ok(bySession['/sessions/2026-01-01_primary.jsonl/TaskSub.jsonl']?.locator?.pid,'subagent still registers (pid + sessionFile, no pane)');
 } finally {
  // Shutdown BOTH adapters (their reconnect timers otherwise keep the
  // process alive) before closing the server.
  hPrimary.get('session_shutdown')?.({},ctxFor('/sessions/2026-01-01_primary.jsonl'));
  hSub.get('session_shutdown')?.({},ctxFor('/sessions/2026-01-01_primary.jsonl/TaskSub.jsonl'));
  await new Promise(r=>setTimeout(r,100));
  const closed=Promise.withResolvers();server.close(closed.resolve);await closed.promise;
  if(oldSocket===undefined)delete process.env.HEELER_CHAT_SOCKET;else process.env.HEELER_CHAT_SOCKET=oldSocket;
  if(oldPane===undefined)delete process.env.HERDR_PANE_ID;else process.env.HERDR_PANE_ID=oldPane;
  await rm(dir,{recursive:true,force:true});
 }
});

// Send correlation: prompt.send(requestKey) must produce a send.confirmed
// event whose recordId IS the committed user record's id (not a marker id).
// Origin is proven by the ATTRIBUTION TOKEN omp echoes into the committed
// record (never text matching): a terminal-typed user message (no token)
// never consumes a key; two sends with IDENTICAL text get distinct, correct
// confirmations for their OWN records.
test('send.confirmed: token-proven origin — real record id, foreign messages, same-text twins', {timeout:5000}, async () => {
 const dir=await mkdtemp(join(tmpdir(),'chat-send-corr-'));
 const socketPath=join(dir,'broker.sock');
 const old=process.env.HEELER_CHAT_SOCKET;
 process.env.HEELER_CHAT_SOCKET=socketPath;
 const handlers=new Map();
 const events=[]; // send.confirmed payloads
 const markers=[]; // durable marker entries appended via pi.appendEntry
 const sentAttributions=[]; // attributions the adapter passed to sendUserMessage
 // Fake session tree mirroring omp: sendUserMessage(text,{attribution}) ->
 // committed user record carries attribution verbatim.
 const mk=(id,parentId,type,message)=>({id,parentId,type,...(message!==undefined?{message}:{})});
 const entries=new Map([
  ['a1',mk('a1',null,'message',{role:'assistant',content:[{type:'text',text:'prior turn'}]})],
 ]);
 let leafId='a1';
 let nextId=0;
 const ctx={sessionManager:{
  getSessionId:()=>'test-session',
  getLeafId:()=>leafId,
  getEntry:id=>entries.get(id),
  appendCustomEntry:(customType,data)=>{const id=`marker-${++nextId}`;entries.set(id,mk(id,leafId,'custom'));markers.push({id,customType,data});return id;},
 },abort(){}};
 // Commit a user record the way omp does: attribution echoed verbatim.
 const commitUser=(text,attribution)=>{const id=`u-${++nextId}`;entries.set(id,mk(id,leafId,'message',{role:'user',content:[{type:'text',text}],attribution}));leafId=id;handlers.get('message_end')({message:{role:'user'}},ctx);return id;};
 // The adapter's queued sends defer like omp: their records commit later,
 // when the fake harness chooses (driven below after each request).
 const queuedForCommit=[];
 let conn;
 const registered=Promise.withResolvers();
 const server=net.createServer(socket=>{
  conn=socket;let buffer='';socket.setEncoding('utf8');
  socket.on('data',chunk=>{
   buffer+=chunk;
   for(;;){const end=buffer.indexOf('\n');if(end<0)break;
    const frame=JSON.parse(buffer.slice(0,end));buffer=buffer.slice(end+1);
    if(frame.type==='hello')socket.write(JSON.stringify({type:'welcome',protocol:1,maxFrameBytes:1048576})+'\n');
    if(frame.type==='register'){socket.write(JSON.stringify({type:'registered'})+'\n');registered.resolve();}
    if(frame.type==='event'&&frame.event?.type==='send.confirmed')events.push(frame.event);
   }
  });
 });
 const request=(params)=>{
  const {promise,resolve}=Promise.withResolvers();
  const id='req-'+Math.random().toString(36).slice(2);
  let buf='';
  const onData=chunk=>{
   buf+=chunk;
   for(;;){const end=buf.indexOf('\n');if(end<0)break;
    const frame=JSON.parse(buf.slice(0,end));buf=buf.slice(end+1);
    if(frame.type==='response'&&frame.id===id){conn.off('data',onData);resolve(frame);}
   }
  };
  conn.on('data',onData);
  conn.write(JSON.stringify({type:'request',id,method:'prompt.send',params})+'\n');
  return promise;
 };
 try {
  server.listen(socketPath);await once(server,'listening');
  extension({
   on:(name,fn)=>handlers.set(name,fn),
   sendUserMessage(content,options){
    const text=typeof content==='string'?content:content.filter(b=>b.type==='text').map(b=>b.text).join(' ');
    const attribution=typeof options?.attribution==='string'?options.attribution:'user';
    sentAttributions.push(attribution);
    queuedForCommit.push({text,attribution});
   },
   getCommands:()=>[],
   appendEntry:(customType,data)=>ctx.sessionManager.appendCustomEntry(customType,data),
  });
  handlers.get('session_start')({},ctx);
  await registered.promise;
  // Broker send k1 (text A). Before its record lands, a TERMINAL-typed user
  // message commits (no token) — must not consume k1.
  const r1=await request({text:'shared text',requestKey:'k1'});
  assert.equal(r1.result?.accepted,true);
  assert.ok(sentAttributions[0].startsWith('heeler-chat:send:'),'send must carry the origin token in attribution');
  assert.equal(sentAttributions[0],'heeler-chat:send:k1');
  commitUser('typed at the terminal','user');
  assert.equal(events.length,0,'a foreign (terminal, tokenless) user message must not emit send.confirmed');
  // k1's record commits: confirms with the REAL id.
  const id1=queuedForCommit.shift();
  const record1=commitUser(id1.text,id1.attribution);
  await new Promise(r=>setTimeout(r,100)); // event delivery over the socket
  assert.equal(events.length,1);
  assert.equal(events[0].requestKey,'k1');
  assert.equal(events[0].recordId,record1,'recordId must be the committed user record id, not a marker id');
  assert.ok(!events[0].recordId.startsWith('marker'),'must not be the marker entry id');
  // THE SAME-TEXT TWIN: send k2 with IDENTICAL text; a same-text terminal
  // message commits in between; k2's record must confirm to ITS OWN id —
  // never confused with the already-confirmed k1 record.
  const r2=await request({text:'shared text',requestKey:'k2'});
  assert.equal(r2.result?.accepted,true);
  assert.equal(sentAttributions[1],'heeler-chat:send:k2');
  commitUser('shared text','user'); // same TEXT as the broker send, tokenless
  assert.equal(events.length,1,'same-text terminal message must not steal k2');
  const id2=queuedForCommit.shift();
  const record2=commitUser(id2.text,id2.attribution);
  await new Promise(r=>setTimeout(r,100));
  assert.equal(events.length,2);
  assert.equal(events[1].requestKey,'k2');
  assert.equal(events[1].recordId,record2);
  assert.notEqual(record1,record2,'identical-text sends confirm to DISTINCT records');
  // The durable markers bind the SAME real record ids.
  assert.equal(markers.length,2);
  assert.equal(markers[0].data.requestKey,'k1');
  assert.equal(markers[0].data.recordId,record1);
  assert.equal(markers[1].data.requestKey,'k2');
  assert.equal(markers[1].data.recordId,record2);
  // Empty FIFO: a terminal message confirms nothing.
  commitUser('typed again at terminal','user');
  assert.equal(events.length,2);
 } finally {
  handlers.get('session_shutdown')?.({},ctx);conn?.destroy();
  const closed=Promise.withResolvers();server.close(closed.resolve);await closed.promise;
  if(old===undefined)delete process.env.HEELER_CHAT_SOCKET;else process.env.HEELER_CHAT_SOCKET=old;
  await rm(dir,{recursive:true,force:true});
 }
});

// Regression (omp 18.2.6 live failure): omp dispatches message_end to
// extensions with the event's OWN message (attribution echoed verbatim),
// but persists the session-tree record ASYNCHRONOUSLY — at event time the
// tree's leaf is STALE (the token-bearing record is not in getEntry yet).
// The leaf-based correlateCommittedSend silently returned early (no marker,
// no send.confirmed). The event-message path must confirm immediately when
// the tree already has the record, and via the turn_end retry when the
// record only lands mid-turn.
test('send.confirmed: stale session tree at message_end — event token proves origin, turn_end retry resolves the real id', {timeout:5000}, async () => {
 const dir=await mkdtemp(join(tmpdir(),'chat-send-stale-'));
 const socketPath=join(dir,'broker.sock');
 const old=process.env.HEELER_CHAT_SOCKET;
 process.env.HEELER_CHAT_SOCKET=socketPath;
 const handlers=new Map();
 const events=[]; // send.confirmed payloads
 const markers=[]; // durable marker entries
 const mk=(id,parentId,type,message)=>({id,parentId,type,...(message!==undefined?{message}:{})});
 const entries=new Map([
  ['a1',mk('a1',null,'message',{role:'assistant',content:[{type:'text',text:'prior turn'}]})],
 ]);
 let leafId='a1';
 let nextId=0;
 const ctx={sessionManager:{
  getSessionId:()=>'test-session',
  getLeafId:()=>leafId,
  getEntry:id=>entries.get(id),
  appendCustomEntry:(customType,data)=>{const id=`marker-${++nextId}`;entries.set(id,mk(id,leafId,'custom'));markers.push({id,customType,data});return id;},
 },abort(){}};
 let conn;
 const registered=Promise.withResolvers();
 const server=net.createServer(socket=>{
  conn=socket;let buffer='';socket.setEncoding('utf8');
  socket.on('data',chunk=>{
   buffer+=chunk;
   for(;;){const end=buffer.indexOf('\n');if(end<0)break;
    const frame=JSON.parse(buffer.slice(0,end));buffer=buffer.slice(end+1);
    if(frame.type==='hello')socket.write(JSON.stringify({type:'welcome',protocol:1,maxFrameBytes:1048576})+'\n');
    if(frame.type==='register'){socket.write(JSON.stringify({type:'registered'})+'\n');registered.resolve();}
    if(frame.type==='event'&&frame.event?.type==='send.confirmed')events.push(frame.event);
   }
  });
 });
 const request=(params)=>{
  const {promise,resolve}=Promise.withResolvers();
  const id='req-'+Math.random().toString(36).slice(2);
  let buf='';
  const onData=chunk=>{
   buf+=chunk;
   for(;;){const end=buf.indexOf('\n');if(end<0)break;
    const frame=JSON.parse(buf.slice(0,end));buf=buf.slice(end+1);
    if(frame.type==='response'&&frame.id===id){conn.off('data',onData);resolve(frame);}
   }
  };
  conn.on('data',onData);
  conn.write(JSON.stringify({type:'request',id,method:'prompt.send',params})+'\n');
  return promise;
 };
 try {
  server.listen(socketPath);await once(server,'listening');
  let committedToken=null;
  extension({
   on:(name,fn)=>handlers.set(name,fn),
   // omp 18.2.6 sendUserMessage: attribution rides the committed message.
   sendUserMessage(content,options){
    committedToken=typeof options?.attribution==='string'?options.attribution:'user';
   },
   getCommands:()=>[],
   appendEntry:(customType,data)=>ctx.sessionManager.appendCustomEntry(customType,data),
  });
  handlers.get('session_start')({},ctx);
  await registered.promise;
  const r1=await request({text:'stale-tree probe',requestKey:'k-stale'});
  assert.equal(r1.result?.accepted,true);
  assert.equal(committedToken,'heeler-chat:send:k-stale');
  // omp 18.2.6 dispatch order: message_end carries the REAL message (token
  // included) while the session-tree append is still in flight — the leaf is
  // the OLD assistant record. The old leaf-based code confirmed NOTHING here.
  handlers.get('message_end')({message:{role:'user',content:[{type:'text',text:'stale-tree probe'}],attribution:committedToken}},ctx);
  await new Promise(r=>setTimeout(r,100));
  assert.equal(events.length,0,'record id must not be guessed while the tree is stale');
  assert.equal(markers.length,0,'no durable marker before the real record id is known');
  // Persistence lands the record; the turn ends. turn_end must resolve the
  // REAL record id from the tree and fire marker + send.confirmed.
  const recordId=`u-${++nextId}`;
  entries.set(recordId,mk(recordId,leafId,'message',{role:'user',content:[{type:'text',text:'stale-tree probe'}],attribution:committedToken}));
  leafId=recordId;
  handlers.get('turn_end')();
  await new Promise(r=>setTimeout(r,100));
  assert.equal(events.length,1,'turn_end retry must emit send.confirmed for the stale-tree send');
  assert.equal(events[0].requestKey,'k-stale');
  assert.equal(events[0].recordId,recordId,'recordId must be the real committed record, resolved from the tree');
  assert.equal(markers.length,1,'durable marker must bind requestKey to the real record id');
  assert.equal(markers[0].data.requestKey,'k-stale');
  assert.equal(markers[0].data.recordId,recordId);
 } finally {
  handlers.get('session_shutdown')?.({},ctx);conn?.destroy();
  const closed=Promise.withResolvers();server.close(closed.resolve);await closed.promise;
  if(old===undefined)delete process.env.HEELER_CHAT_SOCKET;else process.env.HEELER_CHAT_SOCKET=old;
  await rm(dir,{recursive:true,force:true});
 }
});
