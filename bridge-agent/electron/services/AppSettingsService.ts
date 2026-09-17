import { app } from 'electron'
import fs from 'node:fs'
import path from 'node:path'

/**
 * AppSettingsService — tiny UI/lifecycle preferences store.
 *
 * Lives in userData as plain JSON (nothing secret — secrets stay in
 * DeviceStorageService's encrypted store). Currently only tracks the
 * auto-launch choice:
 *   - `null`  → user has never chosen (first run → default ON)
 *   - boolean → the user's explicit choice, respected on every boot
 */
interface AppSettings {
  autoLaunch: boolean | null
}

const DEFAULTS: AppSettings = { autoLaunch: null }

class AppSettingsServiceClass {
  private _cache: AppSettings | null = null

  private getFilePath(): string {
    return path.join(app.getPath('userData'), 'bridge-settings.json')
  }

  load(): AppSettings {
    if (this._cache) return { ...this._cache }
    try {
      if (fs.existsSync(this.getFilePath())) {
        const raw = JSON.parse(fs.readFileSync(this.getFilePath(), 'utf8')) as Partial<AppSettings>
        this._cache = {
          autoLaunch: typeof raw.autoLaunch === 'boolean' ? raw.autoLaunch : null,
        }
        return { ...this._cache }
      }
    } catch (err) {
      console.warn('[AppSettingsService] Failed to load settings, using defaults:', err)
    }
    this._cache = { ...DEFAULTS }
    return { ...this._cache }
  }

  getAutoLaunch(): boolean | null {
    return this.load().autoLaunch
  }

  setAutoLaunch(enabled: boolean): void {
    this._cache = { ...this.load(), autoLaunch: enabled }
    try {
      fs.writeFileSync(this.getFilePath(), JSON.stringify(this._cache, null, 2))
    } catch (err) {
      console.error('[AppSettingsService] Failed to save settings:', err)
    }
  }
}

export const AppSettingsService = new AppSettingsServiceClass()
