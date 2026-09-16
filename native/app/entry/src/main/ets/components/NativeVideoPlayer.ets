import media from '@ohos.multimedia.media';
import { BusinessError } from '@ohos.base';

/** Callbacks emitted by NativeVideoPlayer. Times are in milliseconds. */
export interface NativeVideoPlayerCallbacks {
  onReady: () => void;
  onPlaying: () => void;
  onPaused: () => void;
  onCompleted: () => void;
  onError: (message: string) => void;
  onTimeUpdate: (positionMs: number) => void;
  onDurationUpdate: (durationMs: number) => void;
}

/**
 * Imperative API for NativeVideoPlayer.
 *
 * Keep one controller for one component instance and pass it to the component.
 * The controller owns AVPlayer and serializes replacement/release operations.
 */
export class NativeVideoPlayerController {
  private player: media.AVPlayer | null = null;
  private surfaceId: string = '';
  private pendingUrl: string = '';
  private pendingAutoPlay: boolean = true;
  private pendingVolume: number = 1.0;
  private pendingSpeed: number = 1.0;
  private callbacks: NativeVideoPlayerCallbacks | null = null;
  private generation: number = 0;
  private preparing: boolean = false;
  private preparingGeneration: number = -1;
  private released: boolean = true;
  private readyGeneration: number = -1;

  attach(callbacks: NativeVideoPlayerCallbacks): void {
    this.callbacks = callbacks;
    this.released = false;
  }

  detach(): void {
    this.callbacks = null;
  }

  /** Called by XComponent after its surface is created. */
  setSurfaceReady(surfaceId: string): void {
    if (surfaceId.length === 0 || this.released) {
      return;
    }
    this.surfaceId = surfaceId;
    const current: media.AVPlayer | null = this.player;
    if (current !== null) {
      try {
        current.surfaceId = surfaceId;
      } catch (error) {
        this.emitError(error as BusinessError, '设置视频画面失败');
      }
      return;
    }
    this.tryPrepare();
  }

  /** Open a URL. Repeated calls replace and release the previous player. */
  load(url: string, autoPlay: boolean = true, volume: number = 1.0, speed: number = 1.0): void {
    this.pendingUrl = url;
    this.pendingAutoPlay = autoPlay;
    this.pendingVolume = this.clampVolume(volume);
    this.pendingSpeed = this.clampSpeed(speed);
    this.released = false;
    this.generation += 1;
    this.readyGeneration = -1;
    this.releaseCurrent();
    this.tryPrepare();
  }

  /** Apply changed component properties without reopening the same URL. */
  update(url: string, autoPlay: boolean, volume: number, speed: number): void {
    if (url.length === 0) {
      if (this.pendingUrl.length > 0 || this.player !== null) {
        void this.release();
      }
      return;
    }

    const nextVolume: number = this.clampVolume(volume);
    const nextSpeed: number = this.clampSpeed(speed);
    if (url !== this.pendingUrl || this.released) {
      this.load(url, autoPlay, nextVolume, nextSpeed);
      return;
    }

    this.pendingAutoPlay = autoPlay;
    this.pendingVolume = nextVolume;
    this.pendingSpeed = nextSpeed;
    this.applyPlaybackOptions(this.player);
    if (this.player === null && !this.preparing) {
      this.tryPrepare();
    }
  }

  async play(): Promise<void> {
    const current: media.AVPlayer | null = this.player;
    if (current === null) {
      return;
    }
    try {
      await current.play();
    } catch (error) {
      this.emitError(error as BusinessError, '播放失败');
    }
  }

  async pause(): Promise<void> {
    const current: media.AVPlayer | null = this.player;
    if (current === null) {
      return;
    }
    try {
      if (current.state === 'playing') {
        await current.pause();
      }
    } catch (error) {
      this.emitError(error as BusinessError, '暂停失败');
    }
  }

  seek(positionMs: number): void {
    const current: media.AVPlayer | null = this.player;
    if (current === null) {
      return;
    }
    try {
      current.seek(Math.max(0, Math.floor(positionMs)));
    } catch (error) {
      this.emitError(error as BusinessError, '定位失败');
    }
  }

  async stop(): Promise<void> {
    const current: media.AVPlayer | null = this.player;
    if (current === null) {
      return;
    }
    try {
      if (current.state === 'prepared' || current.state === 'playing' ||
        current.state === 'paused' || current.state === 'completed') {
        await current.stop();
      }
    } catch (error) {
      this.emitError(error as BusinessError, '停止播放失败');
    }
  }

  setVolume(volume: number): void {
    this.pendingVolume = this.clampVolume(volume);
    this.applyVolume(this.player);
  }

  setSpeed(speed: number): void {
    this.pendingSpeed = this.clampSpeed(speed);
    this.applySpeed(this.player);
  }

  async release(): Promise<void> {
    this.released = true;
    this.pendingUrl = '';
    this.surfaceId = '';
    this.generation += 1;
    this.readyGeneration = -1;
    const current: media.AVPlayer | null = this.player;
    this.player = null;
    if (current !== null) {
      await this.disposePlayer(current);
    }
  }

  private releaseCurrent(): void {
    const current: media.AVPlayer | null = this.player;
    this.player = null;
    if (current !== null) {
      void this.disposePlayer(current);
    }
  }

  private tryPrepare(): void {
    if (this.surfaceId.length === 0 || this.pendingUrl.length === 0 ||
      this.released || this.preparing) {
      return;
    }
    const url: string = this.pendingUrl;
    const autoPlay: boolean = this.pendingAutoPlay;
    const generation: number = this.generation;
    this.preparing = true;
    this.preparingGeneration = generation;
    void this.prepare(url, autoPlay, generation);
  }

  private async prepare(url: string, autoPlay: boolean, generation: number): Promise<void> {
    try {
      const created: media.AVPlayer = await media.createAVPlayer();
      if (generation !== this.generation || this.released || this.surfaceId.length === 0) {
        await this.disposePlayer(created);
        return;
      }

      this.player = created;
      created.on('stateChange', (state: media.AVPlayerState, _reason: media.StateChangeReason): void => {
        if (generation !== this.generation || this.player !== created) {
          return;
        }
        if (state === 'prepared') {
          this.emitReady(generation);
        } else if (state === 'playing') {
          this.callbacks?.onPlaying();
        } else if (state === 'paused') {
          this.callbacks?.onPaused();
        } else if (state === 'completed') {
          this.callbacks?.onCompleted();
        }
      });
      created.on('timeUpdate', (positionMs: number): void => {
        if (generation === this.generation && this.player === created) {
          this.callbacks?.onTimeUpdate(Math.max(0, positionMs));
        }
      });
      created.on('durationUpdate', (durationMs: number): void => {
        if (generation === this.generation && this.player === created && durationMs >= 0) {
          this.callbacks?.onDurationUpdate(durationMs);
        }
      });
      created.on('error', (error: BusinessError): void => {
        if (generation === this.generation && this.player === created) {
          this.emitError(error, '播放器发生错误');
        }
      });

      // surfaceId and url must be assigned before prepare().
      created.surfaceId = this.surfaceId;
      created.url = url;
      await created.prepare();
      if (generation !== this.generation || this.released || this.player !== created) {
        await this.disposePlayer(created);
        return;
      }
      this.applyPlaybackOptions(created);
      this.emitReady(generation);
      if (autoPlay) {
        await created.play();
      }
    } catch (error) {
      if (generation === this.generation && !this.released) {
        this.player = null;
        this.emitError(error as BusinessError, '准备播放失败');
      }
    } finally {
      if (this.preparingGeneration === generation) {
        this.preparing = false;
        this.preparingGeneration = -1;
        if (generation !== this.generation) {
          this.tryPrepare();
        }
      }
    }
  }

  private async disposePlayer(player: media.AVPlayer): Promise<void> {
    try {
      player.off('stateChange');
      player.off('timeUpdate');
      player.off('durationUpdate');
      player.off('error');
    } catch (_) {
      // Unregister is best-effort when the player has already failed.
    }
    try {
      if (player.state === 'playing' || player.state === 'paused' ||
        player.state === 'prepared' || player.state === 'completed') {
        await player.stop();
      }
    } catch (_) {
      // A failed or released player can no longer be stopped.
    }
    try {
      await player.release();
    } catch (_) {
      // Release remains best-effort during surface destruction.
    }
  }

  private applyPlaybackOptions(player: media.AVPlayer | null): void {
    this.applyVolume(player);
    this.applySpeed(player);
  }

  private applyVolume(player: media.AVPlayer | null): void {
    if (player === null) {
      return;
    }
    try {
      player.setVolume(this.pendingVolume);
    } catch (error) {
      this.emitError(error as BusinessError, '设置音量失败');
    }
  }

  private applySpeed(player: media.AVPlayer | null): void {
    if (player === null || player.state === 'idle' || player.state === 'initialized') {
      return;
    }
    try {
      player.setSpeed(this.toPlaybackSpeed(this.pendingSpeed));
    } catch (error) {
      this.emitError(error as BusinessError, '设置播放速度失败');
    }
  }

  private toPlaybackSpeed(speed: number): media.PlaybackSpeed {
    if (speed <= 0.5) {
      return media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
    }
    if (speed <= 0.75) {
      return media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    }
    if (speed <= 1.0) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    }
    if (speed <= 1.25) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    }
    if (speed <= 1.5) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
    }
    if (speed <= 1.75) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
    }
    if (speed <= 2.0) {
      return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
    }
    return media.PlaybackSpeed.SPEED_FORWARD_3_00_X;
  }

  private emitReady(generation: number): void {
    if (this.readyGeneration === generation) {
      return;
    }
    this.readyGeneration = generation;
    this.callbacks?.onReady();
  }

  private emitError(error: BusinessError, fallback: string): void {
    let message: string = fallback;
    if (error.message.length > 0) {
      message = `${fallback}（${error.message}）`;
    } else if (error.code > 0) {
      message = `${fallback}（错误码 ${error.code}）`;
    }
    this.callbacks?.onError(message);
  }

  private clampVolume(value: number): number {
    return Math.max(0, Math.min(1, value));
  }

  private clampSpeed(value: number): number {
    return Math.max(0.125, Math.min(3, value));
  }
}

@Component
export struct NativeVideoPlayer {
  @Prop controller: NativeVideoPlayerController = new NativeVideoPlayerController();
  @Prop componentId: string = 'native_video_player';
  @Prop url: string = '';
  @Prop autoPlay: boolean = true;
  @Prop volume: number = 1.0;
  @Prop speed: number = 1.0;
  onSurfaceTouch: (event: TouchEvent) => void = (_event: TouchEvent) => {};
  onReady: () => void = () => {};
  onPlaying: () => void = () => {};
  onPaused: () => void = () => {};
  onCompleted: () => void = () => {};
  onError: (message: string) => void = (_message: string) => {};
  onTimeUpdate: (positionMs: number) => void = (_positionMs: number) => {};
  onDurationUpdate: (durationMs: number) => void = (_durationMs: number) => {};

  private xController: XComponentController = new XComponentController();

  aboutToAppear(): void {
    this.bindCallbacks();
    this.controller.update(this.url, this.autoPlay, this.volume, this.speed);
  }

  aboutToUpdate(): void {
    this.bindCallbacks();
    this.controller.update(this.url, this.autoPlay, this.volume, this.speed);
  }

  aboutToDisappear(): void {
    void this.controller.release();
  }

  private bindCallbacks(): void {
    this.controller.attach({
      onReady: this.onReady,
      onPlaying: this.onPlaying,
      onPaused: this.onPaused,
      onCompleted: this.onCompleted,
      onError: this.onError,
      onTimeUpdate: this.onTimeUpdate,
      onDurationUpdate: this.onDurationUpdate
    });
  }

  build() {
    XComponent({
      id: this.componentId,
      type: XComponentType.SURFACE,
      controller: this.xController
    })
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')
      .onLoad((_event?: object): void => {
        this.controller.setSurfaceReady(this.xController.getXComponentSurfaceId());
      })
      .onTouch((event: TouchEvent): void => {
        this.onSurfaceTouch(event);
      })
      .onDestroy((): void => {
        void this.controller.release();
      });
  }
}
