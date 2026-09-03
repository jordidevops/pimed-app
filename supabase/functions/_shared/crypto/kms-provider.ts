/**
 * KMS abstraction layer for secrets.
 * V1: Supabase Vault (via RPC) + env vars for platform secrets.
 */

export interface EncryptResult {
  ciphertext: string;
  keyVersion: number;
}

export interface KmsProvider {
  encrypt(plaintext: string, keyRef: string): Promise<EncryptResult>;
  decrypt(ciphertext: string, keyRef: string): Promise<string>;
  generateDataKey?(
    keyRef: string,
  ): Promise<{ plaintextKey: string; encryptedKey: string }>;
}

/** Platform secrets from Edge Function environment. */
export class EnvVarKmsProvider implements KmsProvider {
  async encrypt(): Promise<EncryptResult> {
    throw new Error("EnvVarKmsProvider does not support encrypt");
  }

  async decrypt(_ciphertext: string, keyRef: string): Promise<string> {
    const value = Deno.env.get(keyRef);
    if (!value) {
      throw new Error(`Environment secret not configured: ${keyRef}`);
    }
    return value;
  }
}

type ServiceClient = {
  rpc: (
    fn: string,
    args: Record<string, unknown>,
  ) => Promise<{ data: unknown; error: { message: string } | null }>;
};

/** Tenant secrets via api.get_tenant_secret (service_role). */
export class SupabaseVaultKmsProvider implements KmsProvider {
  constructor(
    private readonly client: ServiceClient,
    private readonly accessedByFn: string,
  ) {}

  async encrypt(): Promise<EncryptResult> {
    throw new Error(
      "Use api.upsert_tenant_secret RPC for tenant secret writes",
    );
  }

  /**
   * keyRef format: "tenantId:secretType:provider"
   * Example: "uuid:ai_api_key:openai"
   */
  async decrypt(_ciphertext: string, keyRef: string): Promise<string> {
    const [tenantId, secretType, provider] = keyRef.split(":");
    if (!tenantId || !secretType || !provider) {
      throw new Error(
        `Invalid vault keyRef, expected tenantId:secretType:provider, got: ${keyRef}`,
      );
    }

    const { data, error } = await this.client.rpc("get_tenant_secret", {
      p_tenant_id: tenantId,
      p_secret_type: secretType,
      p_provider: provider,
      p_accessed_by_fn: this.accessedByFn,
      p_access_reason: "kms_provider_decrypt",
    });

    if (error) {
      throw new Error(`get_tenant_secret failed: ${error.message}`);
    }

    if (typeof data !== "string" || !data) {
      throw new Error(`Secret not found: ${keyRef}`);
    }

    return data;
  }
}

export class GcpKmsProvider implements KmsProvider {
  async encrypt(): Promise<EncryptResult> {
    throw new Error("GcpKmsProvider not implemented");
  }
  async decrypt(): Promise<string> {
    throw new Error("GcpKmsProvider not implemented");
  }
}

export class AwsKmsProvider implements KmsProvider {
  async encrypt(): Promise<EncryptResult> {
    throw new Error("AwsKmsProvider not implemented");
  }
  async decrypt(): Promise<string> {
    throw new Error("AwsKmsProvider not implemented");
  }
}

export function createKmsProvider(
  kind: "vault" | "env",
  options: { client?: ServiceClient; accessedByFn?: string; envKey?: string } = {},
): KmsProvider {
  if (kind === "env") {
    return new EnvVarKmsProvider();
  }
  if (!options.client) {
    throw new Error("SupabaseVaultKmsProvider requires a service_role client");
  }
  return new SupabaseVaultKmsProvider(
    options.client,
    options.accessedByFn ?? "kms-provider",
  );
}
