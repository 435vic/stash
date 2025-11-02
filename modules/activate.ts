#! /usr/bin/env -S deno run --allow-env=HOME

import * as path from "jsr:@std/path@1.1.2";

// read: <static file derivation>, each stash's path
// write: $HOME
// asfa

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

interface stashEntry {
    source: string,
    target: string,
    recursive: boolean,
    forced?: boolean
};

const newGeneration = Deno.args[0];
const newGenData: Record<string, stashEntry> = JSON.parse(await Deno.readTextFile(`${newGeneration}/stash.json`));
const newGenStaticFiles = `${newGeneration}/static-files`;

const stashFiles = newGenData;
const HOME = Deno.env.get('HOME')!;

console.log(`HOME: ${HOME}`);

if (!HOME) {
    throw new Error("$HOME must be set.");
}

const statePath = Deno.env.get('XDG_STATE_HOME') || path.join(HOME, '.local/state/stash'); 
const gcRootsPath = path.join(statePath, 'gcroots');
const oldGenPath = path.join(gcRootsPath, 'current-home');
const oldGenDataPath = path.join(oldGenPath, 'stash.json');
const oldGenData: Record<string, stashEntry> = await getFileOrNull(oldGenDataPath, async (_) => {
    const data = await Deno.readTextFile(oldGenDataPath);
    return JSON.parse(data);
});

async function isCollision(sourcePath: string, targetPath: string, forced = false) {
    if (forced) return false;
    const fullTargetPath = path.join(HOME, targetPath);
    const targetStat = await getFileOrNull(fullTargetPath);

    if (targetStat === null) return false;
    // File exists
    const targetRealPath = await Deno.realPath(fullTargetPath);
    if (oldGenData !== null) {
        const oldSources = Object.values(oldGenData).map((file: any) => file.sources);
        if (!oldSources.includes(targetRealPath)) {
            // Path is not current generation, and is not managed by stash
            // this means collision
            return true
        }
    }
    // File exists and but is not managed by stash
    const { code } = await (new Deno.Command("cmp", {
        args: [
            "-s",
            sourcePath,
            targetRealPath,
        ]
    })).output();
    

    // For now assume backups will be done, with extension .bak
    if (code === 0) return false;
    // Files are not identical
    else if (code === 1) return true;
    else {
        console.error(`error running cpm -s ${sourcePath} ${targetRealPath}: code ${code}`);
        throw new Error(`cmp command failed with code ${code}`);
    }
}

if (oldGenData !== null) {
    const collisions = Object.values(oldGenData).filter(async (file: any) => {
        return (await isCollision(file.source, file.target, file.forced));
    });

    if (collisions.length > 0) {
        console.error(`Collisions found for the following files:`);
        for (const collision of collisions) {
            console.error(`  - ${collision.target}`);
        }
    }
}

