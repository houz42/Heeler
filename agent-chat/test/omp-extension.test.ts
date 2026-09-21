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
