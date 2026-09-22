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
  // 4) validations reject (nothing sent on): bad mime, both data+ref, unknown ref.
  const bad=[
   {code:'invalid_request',params:{text:'x',requestKey:'e1',images:[{data:pngB64,mimeType:'image/bmp'}]}},
   {code:'invalid_request',params:{text:'x',requestKey:'e2',images:[{data:pngB64,ref:`img:${entryId}:c:1`,mimeType:'image/png'}]}},
   // Unknown blob ref: the blob store's own contract code, not invalid_request.
   {code:'item_not_found',params:{text:'x',requestKey:'e3',images:[{ref:'img:missing:c:0',mimeType:'image/png'}]}},
   {code:'invalid_request',params:{text:'x',requestKey:'e4',images:[]}},
  ];
  for(const {code,params} of bad){
   const r=await request(params);
   assert.equal(r.error?.code,code,JSON.stringify(params));
   assert.equal(calls.length,3,'no send after a rejected prompt');
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

// Send correlation: prompt.send(requestKey) must produce a send.confirmed
// event whose recordId IS the committed user record's id (not a marker id),
// with origin proven by text match — a terminal-typed user message never
// consumes a pending key and never emits send.confirmed.
test('send.confirmed: real record id, origin-checked, FIFO survives foreign messages', {timeout:5000}, async () => {
 const dir=await mkdtemp(join(tmpdir(),'chat-send-corr-'));
 const socketPath=join(dir,'broker.sock');
 const old=process.env.HEELER_CHAT_SOCKET;
 process.env.HEELER_CHAT_SOCKET=socketPath;
 const handlers=new Map();
 const events=[]; // {type, requestKey, recordId}
 const markers=[]; // durable marker entries appended via pi.appendEntry
 // Fake session tree: entries chain parent->child; the leaf is whatever the
 // "agent" last committed. Start with an assistant message as the leaf.
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
 const commitUser=(text)=>{const id=`u-${++nextId}`;entries.set(id,mk(id,leafId,'message',{role:'user',content:[{type:'text',text}]}));leafId=id;handlers.get('message_end')({message:{role:'user'}},ctx);return id;};
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
   sendUserMessage(){},
   getCommands:()=>[],
   appendEntry:(customType,data)=>ctx.sessionManager.appendCustomEntry(customType,data),
  });
  handlers.get('session_start')({},ctx);
  await registered.promise;
  // Broker sends with requestKey k1; BEFORE its record lands, a TERMINAL-typed
  // user message commits (different text) — it must NOT consume k1.
  const r=await request({text:'broker prompt one',requestKey:'k1'});
  assert.equal(r.result?.accepted,true);
  commitUser('typed at the terminal');
  assert.equal(events.length,0,'a foreign (terminal) user message must not emit send.confirmed');
  // Now the broker prompt's record commits: k1 confirms with the REAL id.
  const recordId=commitUser('broker prompt one');
  await new Promise(r=>setTimeout(r,100)); // event frame delivery over the socket
  assert.equal(events.length,1);
  assert.equal(events[0].requestKey,'k1');
  assert.equal(events[0].recordId,recordId,'recordId must be the committed user record id, not a marker id');
  assert.equal(events[0].recordId.startsWith('u-'),true);
  assert.ok(events[0].recordId!=='marker-1','must not be the marker entry id');
  // The durable marker binds the SAME real record id.
  assert.equal(markers.length,1);
  assert.equal(markers[0].customType,'heeler-chat.send.confirmed');
  assert.equal(markers[0].data.recordId,recordId);
  assert.equal(markers[0].data.requestKey,'k1');
  // A user record with no pending send (empty FIFO) confirms nothing.
  commitUser('typed again at terminal');
  assert.equal(events.length,1);
 } finally {
  handlers.get('session_shutdown')?.({},ctx);conn?.destroy();
  const closed=Promise.withResolvers();server.close(closed.resolve);await closed.promise;
  if(old===undefined)delete process.env.HEELER_CHAT_SOCKET;else process.env.HEELER_CHAT_SOCKET=old;
  await rm(dir,{recursive:true,force:true});
 }
});
