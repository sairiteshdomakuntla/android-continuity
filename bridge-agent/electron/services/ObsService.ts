import { ObsManagerService } from './ObsManagerService.js'

class ObsServiceClass {
  async startVirtualCam(): Promise<boolean> {
    const result = await ObsManagerService.setupAndStartVirtualCamera()
    return result.success
  }

  async stopVirtualCam(): Promise<boolean> {
    return ObsManagerService.stopVirtualCam()
  }
}

export const ObsService = new ObsServiceClass()

