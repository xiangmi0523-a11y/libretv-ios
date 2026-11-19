import type { NextConfig } from 'next';
import fs from 'node:fs';
import path from 'node:path';

/** 版本号以 package.json 为单一来源，构建时注入 process.env.APP_VERSION（/api/status 使用） */
function readAppVersion(): string {
  try {
    const pkg = JSON.parse(fs.readFileSync(path.join(process.cwd(), 'package.json'), 'utf8')) as {
      version?: string;
    };
    return pkg.version || '0.0.0';
  } catch {
    return '0.0.0';
  }
}

/**
 * [LibreTV iOS] App 内置的 nodejs-mobile 只能 --jitless 运行（iOS 禁止 JIT），没有 WebAssembly，
 * 而 undici 依赖 llhttp 的 wasm。构建 iOS 版（IOS_BUILD=1）时把 `undici` 指向基于 http/https 的替身，
 * 其余代码（含 ssrf.ts 的连接级防护）保持原样。
 */
const IOS_UNDICI_SHIM = process.env.IOS_UNDICI_SHIM;

const nextConfig: NextConfig = {
  ...(process.env.IOS_BUILD === '1' && IOS_UNDICI_SHIM
    ? {
        webpack: (config: { resolve: { alias: Record<string, string> } }, { isServer }: { isServer: boolean }) => {
          if (isServer) config.resolve.alias = { ...config.resolve.alias, undici$: IOS_UNDICI_SHIM };
          return config;
        },
      }
    : {}),
  // standalone 输出仅供 Docker 镜像构建使用（DOCKER_BUILD=1）；
  // 本地 next start 在 standalone 模式下不受支持，故按环境切换
  output: process.env.DOCKER_BUILD === '1' ? 'standalone' : undefined,
  reactStrictMode: true,
  env: { APP_VERSION: readAppVersion() },
  // 采集站/豆瓣等上游地址在运行时由用户配置，构建期无法枚举，关闭图片优化改用 <img>
  images: { unoptimized: true },
};

export default nextConfig;
