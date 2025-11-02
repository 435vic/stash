#! /usr/bin/env -S deno run --allow-env=HOME

import * as path from "jsr:@std/path@1.1.2";

// read: <static file derivation>, each stash's path
// write: $HOME

// nix-store --add-root creates the in between directories as well

// 1. Check collisions; a collision occurs if
//   - target exists AND
//   - forced != true AND
//   - source != target (in content, cmp -s) AND
//   - backup not configured or impossible (backup alr exists)
// 2. Clean up old gen's links
//   - Delete links in the old generation NOT in the new generation (cmp by source path)
//   - Recursively delete old directories
// 3. Make new gen's links
//   - Backup target path if it exists and not a symlink (and backups enabled)
//   - If source == target don't symlink, not necessary
//   - place symlink with --force (so target path matches new gen)

if (Deno.args.length !== 1) {
    throw new Error("usage: activate.ts [activation package]");
}

async function getFileOrNull(path: string): Promise<Deno.FileInfo | null>;
async function getFileOrNull<T>(
  path: string, 
  process: (data: Deno.FileInfo) => T
): Promise<T | null>;
async function getFileOrNull<T>(
  path: string, 
  process: (data: Deno.FileInfo) => T = (data: Deno.FileInfo) => data as T
): Promise<T | Deno.FileInfo | null> {
    try {
        const stat = await Deno.stat(path);
        return await process(stat);
    } catch (error) {
        if (error instanceof Deno.errors.NotFound) {
            return null;
        }
        // Re-throw any other unexpected error
        throw error;
    }
}

interface StashEntry {
    source: string,
    target: string,
    recursive: boolean,
    forced?: boolean
};

interface CollisionData {
    collision: boolean,
    backup?: boolean,
    reason?: string
} 

const newGeneration = Deno.args[0];
const newGenData: Record<string, StashEntry> = JSON.parse(await Deno.readTextFile(`${newGeneration}/stash.json`));
const newGenStaticFiles = `${newGeneration}/static-files`;

const stashFiles = newGenData;
const HOME = Deno.env.get('HOME')!;

console.debug(`HOME: ${HOME}`);

if (!HOME) {
    throw new Error("$HOME must be set.");
}

const statePath = Deno.env.get('XDG_STATE_HOME') || path.join(HOME, '.local/state/stash'); 
const gcRootsPath = path.join(statePath, 'gcroots');
const oldGenPath = path.join(gcRootsPath, 'current-home');
const oldGenDataPath = path.join(oldGenPath, 'stash.json');
const oldGenData: Record<string, StashEntry> = await getFileOrNull(oldGenDataPath, async (_) => {
    const data = await Deno.readTextFile(oldGenDataPath);
    return JSON.parse(data);
});

const manifestPath = path.join(statePath, 'manifest.json');
const newManifestPath = path.join(statePath, 'new-manifest.json');

async function isCollision(sourcePath: string, targetPath: string, forced = false): Promise<CollisionData> {
    if (forced) return { collision: false };
    const fullTargetPath = path.join(HOME, targetPath);
    const targetStat = await getFileOrNull(fullTargetPath);

    if (targetStat === null) return { collision: false };
    // target already exists
    const targetRealPath = await Deno.realPath(fullTargetPath);
    if (oldGenData !== null) {
        const oldTargets = Object.values(oldGenData).map((file) => file.target);
        if (oldTargets.includes(targetRealPath)) {
            // target is from previous generation, can be safely overwritten
            return { collision: false }
        }
    }

    const { code } = await (new Deno.Command("cmp", {
        args: [
            "-s",
            sourcePath,
            targetRealPath,
        ]
    })).output();
    
    // files identical
    if (code === 0) return { collision: false };
    // Files are not identical
    // For now assume backups will be done, with extension .bak
    // when backups are implemented, if a backup is not possible then collision should be true
    else if (code === 1) return { collision: false, backup: true }; 
    else {
        console.error(`error running cpm -s ${sourcePath} ${targetRealPath}: code ${code}`);
        throw new Error(`cmp command failed with code ${code}`);
    }
}

async function linkFile() {

}

// files with collision data added on
const files = await Promise.all(Object.values(newGenData).map(async (file) => {
    return {
        data: file,
        collision: await isCollision(file.source, file.target)
    };
}));

const collisions = files.filter(file => !file.data.forced && file.collision);

if (collisions.length > 0) {
    console.error(`Collisions found for the following files:`);
    for (const collision of collisions) {
        console.error(`  - ${collision.data.target}`);
    }
}



