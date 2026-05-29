package app.raven.feature.shell

import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import app.raven.feature.chat.ui.ChatThreadScreen
import app.raven.feature.groups.ui.CreateGroupScreen

/**
 * The post-auth navigation graph. Drops in where the iOS app would
 * have rendered `MainShellView` once `AuthGate` flips to signed-in.
 *
 * Owns its own [androidx.navigation.NavHostController] — the auth
 * graph stays separate so back-stack semantics are clean.
 *
 * Routes today:
 *   • `shell/home` — the tab-bar container (renders InboxScreen +
 *                    placeholder tabs)
 *   • `shell/chat/{peerUserId}` — single conversation screen,
 *                    pushed on top of the shell
 */
@Composable
fun MainShellGraph() {
    val nav = rememberNavController()

    NavHost(navController = nav, startDestination = ShellRoutes.HOME) {
        composable(ShellRoutes.HOME) {
            MainShell(
                onOpenConversation = { conversation ->
                    // A group conversation carries the room id in
                    // `peer.userId` (peer_user_id is null for groups,
                    // so the model falls back to the room id) — that's
                    // the correct key for the message thread. Only the
                    // header labels differ: group name vs. peer name.
                    nav.navigate(
                        ShellRoutes.chatRoute(
                            peerUserId = conversation.peer.userId,
                            peerUsername = if (conversation.isGroup) "" else conversation.peer.username,
                            peerDisplayName = conversation.title,
                            peerAvatarUrl = if (conversation.isGroup) {
                                conversation.groupAvatarUrl
                            } else {
                                conversation.peer.avatarUrl
                            },
                            isGroup = conversation.isGroup,
                        )
                    )
                },
                onNewGroup = { nav.navigate(ShellRoutes.NEW_GROUP) },
            )
        }

        composable(ShellRoutes.NEW_GROUP) {
            CreateGroupScreen(
                onClose = { nav.popBackStack() },
                onGroupCreated = { nav.popBackStack() },
            )
        }

        composable(
            route = ShellRoutes.CHAT,
            arguments = listOf(
                navArgument("peerUserId") { type = NavType.StringType },
                navArgument("peerUsername") { type = NavType.StringType; defaultValue = "" },
                navArgument("peerDisplayName") { type = NavType.StringType; defaultValue = "" },
                navArgument("peerAvatarUrl") {
                    type = NavType.StringType
                    nullable = true
                    defaultValue = null
                },
                navArgument("isGroup") { type = NavType.BoolType; defaultValue = false },
            ),
        ) {
            // VM resolves its args via SavedStateHandle — see
            // ChatThreadViewModel.
            ChatThreadScreen(onBack = { nav.popBackStack() })
        }
    }
}

object ShellRoutes {
    const val HOME = "shell/home"
    const val NEW_GROUP = "shell/new-group"
    const val CHAT = "shell/chat/{peerUserId}?username={peerUsername}" +
        "&displayName={peerDisplayName}&avatar={peerAvatarUrl}&isGroup={isGroup}"

    /**
     * Build a CHAT route URL. `Uri.encode` percent-encodes free-text
     * args and — unlike `URLEncoder` — encodes spaces as `%20`, which
     * Navigation's `Uri.decode` reverses cleanly. (`URLEncoder` emits
     * `+` for space, which Navigation does NOT decode back, so a
     * multi-word name used to surface a literal `+` in the header.)
     */
    fun chatRoute(
        peerUserId: String,
        peerUsername: String,
        peerDisplayName: String,
        peerAvatarUrl: String?,
        isGroup: Boolean,
    ): String {
        val encUser = Uri.encode(peerUsername)
        val encDisplay = Uri.encode(peerDisplayName)
        val encAvatar = peerAvatarUrl?.let { Uri.encode(it) } ?: ""
        return "shell/chat/$peerUserId?username=$encUser" +
            "&displayName=$encDisplay&avatar=$encAvatar&isGroup=$isGroup"
    }
}
