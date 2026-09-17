const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync('web/workspaces.js', 'utf8').split('let workspaceBase')[0];
vm.runInThisContext(source);
const note = {id:'note',type:'blank',title:'Notes'};
const artifact = {id:'cip',type:'html',title:'CIP',html:'First version'};
const before = {sapi:{tabs:[note],activeTab:'note'}};
const local = {sapi:{tabs:[{...note,title:'Human notes'}],activeTab:'note'}};
const remote = {sapi:{tabs:[note,artifact],activeTab:'cip'}};
const merged = mergeWorkspaces(before,local,remote);
assert.equal(merged.sapi.tabs[0].title,'Human notes');
assert.deepEqual(merged.sapi.tabs[1],artifact);
assert.equal(merged.sapi.activeTab,'cip');
// A local close survives a host update to another Sapi's workspace.
assert.deepEqual(mergeWorkspaces(remote,before,remote),before);
// Host edits and removals are reflected without reviving old tabs.
const updated = {sapi:{tabs:[note,{...artifact,html:'Updated'}],activeTab:'cip'}};
assert.equal(mergeWorkspaces(remote,remote,updated).sapi.tabs[1].html,'Updated');
assert.deepEqual(mergeWorkspaces(remote,remote,before),before);
// A save acknowledgement uses the submitted snapshot as base: typing in flight survives.
assert.deepEqual(mergeWorkspaces(before,local,before),local);
console.log('Workspace reconciliation checks passed');
