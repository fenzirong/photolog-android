package io.photolog.android.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.IosShare
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import io.photolog.android.AppContainer
import io.photolog.android.data.PhotoSource
import io.photolog.android.vm.CaptureViewModel
import io.photolog.android.vm.DetailViewModel
import io.photolog.android.vm.ExportViewModel
import io.photolog.android.vm.GalleryViewModel
import io.photolog.android.vm.PhotoLogViewModelFactory
import io.photolog.android.vm.SettingsViewModel

/** Route names, in one place so a typo cannot create a silently unreachable screen. */
object Routes {
    const val GALLERY = "gallery"
    const val CAPTURE = "capture"
    const val EXPORT = "export"
    const val SETTINGS = "settings"
    const val DETAIL = "detail/{photoId}"

    fun detail(photoId: Long): String = "detail/$photoId"
}

private data class Tab(
    val route: String,
    val label: String,
    val selectedIcon: ImageVector,
    val unselectedIcon: ImageVector,
)

private val TABS = listOf(
    Tab(Routes.GALLERY, "图库", Icons.Filled.PhotoLibrary, Icons.Outlined.PhotoLibrary),
    Tab(Routes.CAPTURE, "拍照", Icons.Filled.PhotoCamera, Icons.Outlined.PhotoCamera),
    Tab(Routes.EXPORT, "导出", Icons.Filled.IosShare, Icons.Outlined.IosShare),
    Tab(Routes.SETTINGS, "设置", Icons.Filled.Settings, Icons.Outlined.Settings),
)

/**
 * The bottom navigation bar.
 *
 * Four destinations: a flat set of top-level tabs with no drawer and no hamburger. Everything
 * is one tap away and the back stack stays shallow.
 */
@Composable
fun PhotoLogBottomBar(navController: NavHostController) {
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = backStackEntry?.destination?.route

    NavigationBar {
        TABS.forEach { tab ->
            val selected = currentRoute == tab.route
            NavigationBarItem(
                selected = selected,
                onClick = {
                    if (!selected) {
                        // `launchSingleTop` keeps repeated taps from stacking duplicates, and
                        // `restoreState` returns the tab to where the user left it.
                        navController.navigate(tab.route) {
                            popUpTo(navController.graph.startDestinationId) { saveState = true }
                            launchSingleTop = true
                            restoreState = true
                        }
                    }
                },
                icon = {
                    Icon(
                        imageVector = if (selected) tab.selectedIcon else tab.unselectedIcon,
                        contentDescription = tab.label,
                    )
                },
                label = { Text(tab.label) },
            )
        }
    }
}

/**
 * The navigation graph, and the one place incoming shares are consumed.
 *
 * Every top-level screen owns its own `Scaffold` (top bar, and the shared bottom bar) rather
 * than nesting inside one shared Scaffold. Nesting would mean two layers both applying window
 * insets, which is the usual cause of a bottom bar floating above a gap.
 */
@Composable
fun PhotoLogRoot(container: AppContainer) {
    val navController = rememberNavController()

    /*
     * The share intake lives at the root, not in a screen.
     *
     * A shared image must be imported whichever tab happens to be open — and on a cold start
     * from the share sheet, the activity is created *by* the intent, so this collector is the
     * first thing that can possibly see it. Doing it in a screen's ViewModel would lose every
     * share that arrived while that screen was not composed.
     */
    LaunchedEffect(Unit) {
        container.intake.batches.collect { uris ->
            val summary = container.repository.importUris(uris, PhotoSource.SHARE)
            container.messages.post(summary.describe())
            if (summary.firstAddedId != null) {
                navController.navigate(Routes.GALLERY) { launchSingleTop = true }
            }
        }
    }

    NavHost(navController = navController, startDestination = Routes.GALLERY) {
        composable(Routes.GALLERY) {
            val viewModel: GalleryViewModel = viewModel(factory = PhotoLogViewModelFactory(container))
            GalleryScreen(
                viewModel = viewModel,
                navController = navController,
                onOpenCamera = { navController.navigateToTab(Routes.CAPTURE) },
            )
        }

        composable(Routes.CAPTURE) {
            val viewModel: CaptureViewModel = viewModel(factory = PhotoLogViewModelFactory(container))
            CaptureScreen(
                viewModel = viewModel,
                navController = navController,
                onOpenPhoto = { photoId -> navController.navigate(Routes.detail(photoId)) },
            )
        }

        composable(Routes.EXPORT) {
            val viewModel: ExportViewModel = viewModel(factory = PhotoLogViewModelFactory(container))
            ExportScreen(viewModel = viewModel, navController = navController)
        }

        composable(Routes.SETTINGS) {
            val viewModel: SettingsViewModel = viewModel(factory = PhotoLogViewModelFactory(container))
            SettingsScreen(viewModel = viewModel, navController = navController)
        }

        composable(
            route = Routes.DETAIL,
            arguments = listOf(navArgument("photoId") { type = NavType.LongType }),
        ) { entry ->
            val photoId = entry.arguments?.getLong("photoId") ?: 0L
            val viewModel: DetailViewModel = viewModel(
                factory = PhotoLogViewModelFactory(container, photoId = photoId),
            )
            DetailScreen(viewModel = viewModel, onBack = { navController.popBackStack() })
        }
    }
}

/** Tab-to-tab navigation, with the state of the tab being left preserved. */
internal fun NavHostController.navigateToTab(route: String) {
    navigate(route) {
        popUpTo(graph.startDestinationId) { saveState = true }
        launchSingleTop = true
        restoreState = true
    }
}
