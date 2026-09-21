import asset from '@ohos.security.asset';
import cryptoFramework from '@ohos.security.cryptoFramework';
import buffer from '@ohos.buffer';
import util from '@ohos.util';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';

const DOMAIN: number = 0x0000;
const TAG: string = 'SecureStore';

/**
 * 本机敏感数据的加密底座。
 *
 * 设计（不要轻易改动，变了会导致已存数据解不开 / 登录态丢失）：
 *
 * 1. 主密钥（32 字节 AES-256 随机密钥）**只存系统关键资产库**（`@ohos.security.asset`），
 *    由系统用硬件/TEE 派生的密钥加密后落盘；应用 preferences 里**不出现**该密钥。
 * 2. 业务数据用 AES-256-GCM 加密，**每次加密重新生成 IV**，密文以
 *    `enc:v1:<base64(iv||ciphertext||authTag)>` 的信封形式交给调用方保存
 *    （GCM 的 authTag 由 Cipher.doFinal(null) 返回，16 字节，附在密文末尾）。
 * 3. 用 AES-GCM 而不是 CBC：自带完整性校验，密文被篡改会直接解密失败，
 *    不会被当成合法明文继续使用。
 *
 * 为什么密钥放 Asset 而不是自己生成一个固定字符串：固定字符串等于没有加密；
 * Asset 的密钥不进入应用数据目录，普通文件读取/备份无法取得。
 */
export class SecureStore {
  /** 主密钥在系统关键资产库中的别名（同一应用内全局唯一） */
  private static readonly KEY_ALIAS: string = 'jellyfin_hmos_master_key_v1';
  /** 密文信封前缀 + 版本号，用于识别"已加密"与兼容未来换算法 */
  private static readonly ENVELOPE_PREFIX: string = 'enc:v1:';
  private static readonly AES_ALG: string = 'AES256';
  private static readonly CIPHER_ALG: string = 'AES256|GCM';
  private static readonly IV_LEN: number = 12;
  private static readonly AUTH_TAG_LEN: number = 16;
  /** 主密钥暂时不可用（区别于"数据不可用"），用于避免调用方误删完好数据 */
  private static readonly KEY_UNAVAILABLE: string = 'SecureStoreKeyUnavailable';

  private static symKey: cryptoFramework.SymKey | null = null;

  // ---------------- 对外 API ----------------

  /** 判断一个值是否已是本模块产出的密文信封 */
  static isEncrypted(value: string): boolean {
    return value.startsWith(SecureStore.ENVELOPE_PREFIX);
  }

  /**
   * 加密明文为可落盘的信封字符串；已加密的值原样返回（幂等）。
   * 加密底座不可用时抛异常，绝不静默降级为明文 —— 调用方应据此报错而不是写明文。
   */
  static encrypt(plain: string): string {
    if (plain.length === 0 || SecureStore.isEncrypted(plain)) {
      return plain;
    }
    const key: cryptoFramework.SymKey = SecureStore.getSymKey();
    const ivBlob: cryptoFramework.DataBlob = cryptoFramework.createRandom().generateRandomSync(SecureStore.IV_LEN);
    const gcmParams: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: ivBlob,
      aad: { data: new Uint8Array(0) },
      authTag: { data: new Uint8Array(0) }
    };
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher(SecureStore.CIPHER_ALG);
    cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, gcmParams);
    const plainBlob: cryptoFramework.DataBlob = { data: SecureStore.toBytes(plain) };
    const cipherBlob: cryptoFramework.DataBlob = cipher.updateSync(plainBlob);
    // GCM 下 doFinal(null) 的结果就是 authTag，密文本体全部来自 update
    const tagBlob: cryptoFramework.DataBlob = cipher.doFinalSync(null);
    const out: Uint8Array = new Uint8Array(ivBlob.data.length + cipherBlob.data.length + tagBlob.data.length);
    out.set(ivBlob.data, 0);
    out.set(cipherBlob.data, ivBlob.data.length);
    out.set(tagBlob.data, ivBlob.data.length + cipherBlob.data.length);
    return SecureStore.ENVELOPE_PREFIX + buffer.from(out).toString('base64');
  }

  /**
   * 解密信封字符串。
   *
   * 三种"拿不到明文"的情况必须区分对待，否则会造成数据损坏或卡死：
   * - 空串 → 空串（本来就没有数据）
   * - 未加密（历史明文数据）→ 原样返回，调用方据此触发迁移
   * - 已加密但数据不可用（被篡改/截断，或主密钥已被删除/更换）→ 返回空串。
   *   此时**密钥是可用的**，只是这段数据永远解不开了，调用方可以安全地丢弃它。
   * - **主密钥暂时取不到（资产服务异常等）→ 抛 `KEY_UNAVAILABLE`**。
   *   调用方必须把这种情况当成"暂时读不到"，绝不能因此删除数据
   *   （否则一次瞬时故障就会把用户完好的登录态清掉）。
   */
  static decrypt(value: string): string {
    if (value.length === 0) {
      return '';
    }
    if (!SecureStore.isEncrypted(value)) {
      return value;
    }
    const parsed: Uint8Array | null = SecureStore.parseEnvelope(value);
    if (parsed === null) {
      hilog.warn(DOMAIN, TAG, 'decrypt: malformed envelope');
      return '';
    }
    const raw: Uint8Array = parsed;
    if (raw.length <= SecureStore.IV_LEN + SecureStore.AUTH_TAG_LEN) {
      hilog.warn(DOMAIN, TAG, 'decrypt: envelope too short');
      return '';
    }
    // 故意放在 try 之外：密钥取不到时按"暂时不可用"抛出，不做成空值
    const key: cryptoFramework.SymKey = SecureStore.getSymKey();
    try {
      const iv: Uint8Array = raw.subarray(0, SecureStore.IV_LEN);
      const body: Uint8Array = raw.subarray(SecureStore.IV_LEN, raw.length - SecureStore.AUTH_TAG_LEN);
      const tag: Uint8Array = raw.subarray(raw.length - SecureStore.AUTH_TAG_LEN);
      const gcmParams: cryptoFramework.GcmParamsSpec = {
        algName: 'GcmParamsSpec',
        iv: { data: iv },
        aad: { data: new Uint8Array(0) },
        authTag: { data: tag }
      };
      const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher(SecureStore.CIPHER_ALG);
      cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, key, gcmParams);
      const plainBlob: cryptoFramework.DataBlob = cipher.updateSync({ data: body });
      cipher.doFinalSync(null);
      return SecureStore.fromBytes(plainBlob.data);
    } catch (error) {
      // 密钥可用但 GCM 校验失败 → 数据确实不可用（不可恢复）
      hilog.error(DOMAIN, TAG, 'decrypt failed: %{public}s', JSON.stringify(error as BusinessError));
      return '';
    }
  }

  /** 判断某个错误是否表示"主密钥暂时不可用"（调用方据此避免把完好数据当成空值丢弃） */
  static isKeyUnavailable(error: ESObject): boolean {
    return error instanceof Error && error.name === SecureStore.KEY_UNAVAILABLE;
  }

  /** 解析信封为字节；格式非法时返回 null */
  private static parseEnvelope(value: string): Uint8Array | null {
    try {
      return new Uint8Array(buffer.from(
        value.substring(SecureStore.ENVELOPE_PREFIX.length), 'base64').buffer);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'parseEnvelope failed: %{public}s', JSON.stringify(error as BusinessError));
      return null;
    }
  }

  /** 删除主密钥（清除数据/注销时调用）。密钥一旦删除，历史密文将永久不可解。 */
  static clearKey(): void {
    SecureStore.symKey = null;
    try {
      asset.removeSync(SecureStore.aliasQuery());
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      // 24000002 = 资产不存在；此时本就无需清理，不算失败
      if (err.code !== asset.ErrorCode.NOT_FOUND) {
        hilog.warn(DOMAIN, TAG, 'clearKey failed: %{public}s', JSON.stringify(err));
      }
    }
  }

  // ---------------- 内部实现 ----------------

  /** 资产别名（Alias 必须是 Uint8Array） */
  private static aliasValue(): Uint8Array {
    return SecureStore.toBytes(SecureStore.KEY_ALIAS);
  }

  /** 仅按别名定位资产的查询条件 */
  private static aliasQuery(): asset.AssetMap {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, SecureStore.aliasValue());
    return query;
  }

  /**
   * 取主密钥：优先内存缓存 → 系统资产库 → 尚未创建时随机生成并写入资产库。
   *
   * 注意：`IS_PERSISTENT` 用于"设备重启后仍然保留"，它要求
   * `ohos.permission.STORE_PERSISTENT_DATA` 权限（已在 module.json5 声明）。
   *
   * **关键安全约定**：只有"资产确实不存在"（NOT_FOUND）才允许新建密钥。
   * 其它任何失败（服务不可用 / 权限不足 / IPC 异常等）都必须抛出去，
   * 否则会在一次瞬时故障后生成新密钥并覆盖掉原密钥，导致历史密文永久不可解、
   * 用户被静默登出且再也取不回数据。
   */
  private static getSymKey(): cryptoFramework.SymKey {
    if (SecureStore.symKey !== null) {
      return SecureStore.symKey;
    }
    const existing: Uint8Array | null = SecureStore.loadKeyFromAsset();
    if (existing !== null) {
      if (existing.length !== 32) {
        // 已有密钥但长度异常：绝不覆盖（覆盖等于丢弃所有历史密文）
        throw new Error(`unexpected master key length: ${existing.length}`);
      }
      SecureStore.symKey = cryptoFramework.createSymKeyGenerator(SecureStore.AES_ALG).convertKeySync({ data: existing });
      return SecureStore.symKey;
    }
    const generated: cryptoFramework.SymKey =
      cryptoFramework.createSymKeyGenerator(SecureStore.AES_ALG).generateSymKeySync();
    const keyBytes: Uint8Array = new Uint8Array(generated.getEncoded().data);
    SecureStore.saveKeyToAsset(keyBytes);
    SecureStore.symKey = generated;
    hilog.info(DOMAIN, TAG, 'master key created in system asset store');
    return SecureStore.symKey;
  }

  /**
   * 从资产库读取主密钥。
   *
   * @returns 密钥字节；资产不存在时返回 `null`（表示可以安全创建新密钥）
   * @throws 资产服务异常 / 权限不足等错误 —— 调用方**不得**据此新建密钥
   */
  private static loadKeyFromAsset(): Uint8Array | null {
    try {
      const query: asset.AssetMap = SecureStore.aliasQuery();
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const results: Array<asset.AssetMap> = asset.querySync(query);
      if (results.length === 0) {
        return null;
      }
      const secret: asset.Value | undefined = results[0].get(asset.Tag.SECRET);
      if (secret instanceof Uint8Array && secret.length > 0) {
        return secret;
      }
      // 查到资产却没有密钥：数据已损坏，不能当作"不存在"直接覆盖
      throw new Error('asset found but secret is missing or empty');
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      if (err.code === asset.ErrorCode.NOT_FOUND) {
        return null;
      }
      hilog.error(DOMAIN, TAG, 'loadKeyFromAsset failed: %{public}s', JSON.stringify(err));
      // 打上标记，供调用方区分"密钥暂时不可用"与"数据不可用"
      const wrapped: Error = new Error(`master key unavailable: ${JSON.stringify(err)}`);
      wrapped.name = SecureStore.KEY_UNAVAILABLE;
      throw wrapped;
    }
  }

  private static saveKeyToAsset(keyBytes: Uint8Array): void {
    const attributes: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attributes.set(asset.Tag.ALIAS, SecureStore.aliasValue());
    attributes.set(asset.Tag.SECRET, keyBytes);
    // 首次解锁后可读：开机未解锁时应用也无法启动，不牺牲可用性
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.IS_PERSISTENT, true);
    // 别名冲突时覆盖，避免"半初始化"状态下卡死
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    // 不做跨设备同步（NEVER）：会话令牌是本机凭证，不应跟随云同步/克隆扩散
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    try {
      asset.addSync(attributes);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      // 并发/重复创建：已存在即可直接复用，不算错误
      if (err.code !== asset.ErrorCode.DUPLICATED) {
        throw err as Error;
      }
    }
  }

  /** UTF-8 字符串 → 字节 */
  private static toBytes(text: string): Uint8Array {
    return new Uint8Array(buffer.from(text, 'utf-8').buffer);
  }

  /** 字节 → UTF-8 字符串 */
  private static fromBytes(bytes: Uint8Array): string {
    return util.TextDecoder.create('utf-8').decodeToString(bytes);
  }
}
