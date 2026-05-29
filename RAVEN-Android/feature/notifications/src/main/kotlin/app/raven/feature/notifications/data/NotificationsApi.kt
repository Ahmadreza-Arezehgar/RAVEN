package app.raven.feature.notifications.data

import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.Path
import retrofit2.http.Query

interface NotificationsApi {

    @GET("api/notifications")
    suspend fun getNotifications(@Query("limit") limit: Int = 50): List<NotificationDto>

    @POST("api/notifications/read-all")
    suspend fun markAllRead()

    @POST("api/notifications/{id}/read")
    suspend fun markRead(@Path("id") id: String)
}
