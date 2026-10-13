import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const html = fs.readFileSync(new URL('../../Hitachi-CSI-log-Bundle-Viewer.html', import.meta.url), 'utf8');

function extractFunction(source, name) {
    const start = source.indexOf(`function ${name}(`);
    if (start < 0) return null;
    const open = source.indexOf('{', start);
    let depth = 0;
    for (let i = open; i < source.length; i++) {
        const ch = source[i];
        if (ch === '{') depth++;
        else if (ch === '}') {
            depth--;
            if (depth === 0) return source.slice(start, i + 1);
        }
    }
    throw new Error(`unterminated function ${name}`);
}

function loadParsers() {
    const names = [
        'splitTopLevelYamlObjects',
        'parseStorageClassBlock',
        'parseStorageClasses',
        'parseVolumeSnapshotClassBlocks',
        'parseVolumeSnapshotClasses',
        'getStorageClassDetails',
    ];
    const bodies = names.map((name) => extractFunction(html, name)).filter(Boolean);
    const context = {
        console,
        state: {
            config: { storageClasses: [], volumeSnapshotClasses: [] },
            clusterContext: '',
        },
    };
    vm.createContext(context);
    vm.runInContext(bodies.join('\n'), context);
    return context;
}

const browserStorageClasses = `
=== HSPC StorageClasses ===
metadata:
  name: sc-70077-2pfc
  uid: f26336ae-ae68-455f-acd9-a51d7b407025
  creationTimestamp: '2026-10-08T20:02:40Z'
provisioner: hspc.csi.hitachi.com
parameters:
  connectionType: fc
  poolID: '6'
  portID: CL7-A,CL5-A
  serialNumber: '70077'
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: sc-second
  creationTimestamp: '2026-10-09T00:00:00Z'
provisioner: hspc.csi.hitachi.com
parameters:
  serialNumber: '70078'
  portID: CL1-A
reclaimPolicy: Retain
allowVolumeExpansion: false
volumeBindingMode: WaitForFirstConsumer
apiVersion: storage.k8s.io/v1
kind: StorageClass

=== Pod Ownership Chain ===
`;

const shellStorageClasses = `
=== HSPC StorageClasses ===
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  creationTimestamp: "2025-10-15T22:46:00Z"
  name: dc-1-sc-1-445824
parameters:
  poolID: "0"
  portID: CL2-A,CL3-A
  serialNumber: "445824"
provisioner: hspc.csi.hitachi.com
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  creationTimestamp: "2025-11-03T23:07:08Z"
  name: sc-gold-replicated
parameters:
  replicationType: stretched
  serialNumber: "445824"
provisioner: hspc.csi.hitachi.com
reclaimPolicy: Delete
volumeBindingMode: Immediate

=== Pod Ownership Chain ===
`;

const browserSnapshotClasses = `
=== HSPC VolumeSnapshotClasses ===
metadata:
  name: snap-70077
  creationTimestamp: '2026-04-28T18:11:06Z'
  labels:
    storageclass-ref: sc-70077-2pfc
    velero.io/csi-volumesnapshot-class: 'true'
driver: hspc.csi.hitachi.com
deletionPolicy: Delete
parameters:
  poolID: '0'
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: snap-70077-retain
  creationTimestamp: '2026-05-26T01:57:58Z'
  labels:
    storageclass-ref: sc-70077-2pfc
driver: hspc.csi.hitachi.com
deletionPolicy: Retain
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass

=== Pod Ownership Chain ===
`;

const shellSnapshotClasses = `
=== HSPC VolumeSnapshotClasses ===
apiVersion: snapshot.storage.k8s.io/v1
deletionPolicy: Delete
driver: hspc.csi.hitachi.com
kind: VolumeSnapshotClass
metadata:
  creationTimestamp: "2026-04-28T18:11:06Z"
  labels:
    storageclass-ref: dc-1-sc-1-445824
  name: snapshot-dc-1-sc-1-445824
parameters:
  poolID: "0"
apiVersion: snapshot.storage.k8s.io/v1
deletionPolicy: Retain
driver: hspc.csi.hitachi.com
kind: VolumeSnapshotClass
metadata:
  creationTimestamp: "2026-05-26T01:57:58Z"
  labels:
    storageclass-ref: dc-1-sc-1-445824
    velero.io/csi-volumesnapshot-class: "true"
  name: snapshot-dc-1-sc-1-445824-velero
parameters:
  poolID: "0"

=== LocalVolumes ===
`;

test('browser key order keeps each storage class, including single-quoted timestamps', () => {
    const { state, parseStorageClasses } = loadParsers();
    parseStorageClasses(browserStorageClasses);
    assert.equal(state.config.storageClasses.length, 2);
    const first = state.config.storageClasses[0];
    assert.equal(first.name, 'sc-70077-2pfc');
    assert.equal(first.allowVolumeExpansion, true);
    assert.equal(first.volumeBindingMode, 'Immediate');
    assert.equal(first.reclaimPolicy, 'Delete');
    assert.equal(first.creationTimestamp, '2026-10-08T20:02:40Z');
    assert.equal(first.parameters.serialNumber, '70077');
    assert.equal(first.parameters.portID, 'CL7-A,CL5-A');
    assert.equal(state.config.storageClasses[1].name, 'sc-second');
    assert.equal(state.config.storageClasses[1].allowVolumeExpansion, false);
});

test('shell collector key order still parses multiple storage classes', () => {
    const { state, parseStorageClasses } = loadParsers();
    parseStorageClasses(shellStorageClasses);
    assert.deepEqual(Array.from(state.config.storageClasses, (sc) => sc.name), ['dc-1-sc-1-445824', 'sc-gold-replicated']);
    assert.equal(state.config.storageClasses[0].isDefault, true);
    assert.equal(state.config.storageClasses[0].creationTimestamp, '2025-10-15T22:46:00Z');
    assert.equal(state.config.storageClasses[0].parameters.serialNumber, '445824');
    assert.equal(state.config.storageClasses[1].type, 'stretched');
});

test('browser key order parses volume snapshot classes', () => {
    const { state, parseVolumeSnapshotClasses } = loadParsers();
    parseVolumeSnapshotClasses(browserSnapshotClasses);
    assert.equal(state.config.volumeSnapshotClasses.length, 2);
    assert.equal(state.config.volumeSnapshotClasses[0].name, 'snap-70077');
    assert.equal(state.config.volumeSnapshotClasses[0].creationTimestamp, '2026-04-28T18:11:06Z');
    assert.equal(state.config.volumeSnapshotClasses[0].storageClassRef, 'sc-70077-2pfc');
    assert.equal(state.config.volumeSnapshotClasses[0].isVelero, true);
    assert.equal(state.config.volumeSnapshotClasses[0].deletionPolicy, 'Delete');
    assert.equal(state.config.volumeSnapshotClasses[1].name, 'snap-70077-retain');
    assert.equal(state.config.volumeSnapshotClasses[1].deletionPolicy, 'Retain');
});

test('shell collector key order still parses volume snapshot classes', () => {
    const { state, parseVolumeSnapshotClasses } = loadParsers();
    parseVolumeSnapshotClasses(shellSnapshotClasses);
    assert.deepEqual(
        Array.from(state.config.volumeSnapshotClasses, (vsc) => vsc.name),
        ['snapshot-dc-1-sc-1-445824', 'snapshot-dc-1-sc-1-445824-velero']
    );
    assert.equal(state.config.volumeSnapshotClasses[1].isVelero, true);
    assert.equal(state.config.volumeSnapshotClasses[0].creationTimestamp, '2026-04-28T18:11:06Z');
});

test('storage class tooltip lookup uses the same object split', () => {
    const ctx = loadParsers();
    ctx.state.clusterContext = browserStorageClasses;
    const sc = ctx.getStorageClassDetails(null, 'sc-70077-2pfc');
    assert.ok(sc);
    assert.equal(sc.creationTimestamp, '2026-10-08T20:02:40Z');
    assert.equal(sc.parameters.serialNumber, '70077');
    assert.equal(sc.allowVolumeExpansion, true);
});
