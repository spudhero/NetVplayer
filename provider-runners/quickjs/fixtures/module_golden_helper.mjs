globalThis.__quickjsGoldenModuleLoads = (globalThis.__quickjsGoldenModuleLoads || 0) + 1;

export function moduleGoldenValue() {
    return globalThis.__quickjsGoldenModuleLoads;
}
