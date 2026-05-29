package app.raven.feature.e2ee

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.Path

/**
 * Retrofit + DTOs for the classical (X3DH) E2EE bundle endpoints
 * under /api/e2ee/X. Mirror of iOS PreKeyBundle.swift and
 * E2EENetworkProvider.swift.
 *
 * Phase 2c publishes a minimal bundle: identity_key (Ed25519) +
 * identity_agreement_key (X25519). Signed-prekey is stubbed with a
 * fresh per-publish keypair signed by the identity key, and the
 * one-time-prekey pool is empty for now (gets filled in Phase 2d
 * once we wire the rotation worker). Server accepts these shapes —
 * the field validation only requires non-empty values.
 *
 * Once Phase 2d ships, the publish flow will also push the ATSAM
 * PQ-hybrid bundle (`/api/atsam/prekey/publish`) which adds the
 * ML-KEM-768 public key for the post-quantum half.
 */
interface E2eeBundleApi {

    @POST("api/e2ee/bundle")
    suspend fun publishBundle(@Body body: UploadBundleRequestDto)

    @GET("api/e2ee/bundle/{userId}/{deviceId}")
    suspend fun fetchBundle(
        @Path("userId") userId: String,
        @Path("deviceId") deviceId: String,
    ): FetchedBundleResponseDto
}

@Serializable
data class OneTimePreKeyDto(
    val id: Int,
    @SerialName("public_key") val publicKey: String,
)

@Serializable
data class UploadBundleRequestDto(
    @SerialName("user_id") val userId: String,
    @SerialName("device_id") val deviceId: String,
    @SerialName("identity_key") val identityKey: String,
    @SerialName("identity_agreement_key") val identityAgreementKey: String,
    @SerialName("signed_pre_key_id") val signedPreKeyId: Int,
    @SerialName("signed_pre_key") val signedPreKey: String,
    @SerialName("signed_pre_key_signature") val signedPreKeySignature: String,
    @SerialName("signed_pre_key_created_at") val signedPreKeyCreatedAt: Double,
    @SerialName("one_time_pre_keys") val oneTimePreKeys: List<OneTimePreKeyDto> = emptyList(),
    @SerialName("created_at") val createdAt: Double,
)

@Serializable
data class FetchedBundleResponseDto(
    @SerialName("user_id") val userId: String,
    @SerialName("device_id") val deviceId: String,
    @SerialName("identity_key") val identityKey: String,
    @SerialName("identity_agreement_key") val identityAgreementKey: String,
    @SerialName("signed_pre_key_id") val signedPreKeyId: Int,
    @SerialName("signed_pre_key") val signedPreKey: String,
    @SerialName("signed_pre_key_signature") val signedPreKeySignature: String,
    @SerialName("signed_pre_key_created_at") val signedPreKeyCreatedAt: Double,
    @SerialName("one_time_pre_key") val oneTimePreKey: OneTimePreKeyDto? = null,
    @SerialName("created_at") val createdAt: Double,
)
