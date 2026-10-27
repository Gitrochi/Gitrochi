//! Gitrochi 백엔드: 화면(웹)은 여기 명령으로 git·셸·파일·네트워크·자격 증명을 다룬다.
//! git 동작은 새로 구현하지 않고 시스템 git 을 그대로 실행한다.

mod agents;
pub mod helper;
mod net;
mod launch;
mod local_projects;
mod process;
mod pty;
mod system;
mod update;
mod watch;

use tauri::Manager;

pub fn run() {
    tauri::Builder::default()
        // 이미 켜져 있으면 새로 띄우지 않고 기존 창을 앞으로
        .manage(launch::Pending::default())
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
            launch::receive(app, args);
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.unminimize();
                let _ = w.show();
                let _ = w.set_focus();
            }
        }))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(update::PendingUpdate::default())
        .setup(|app| {
            launch::receive(app.handle(), std::env::args().collect());
            // 배포본에서는 웹뷰의 브라우저 단축키(F5 새로 고침, Ctrl+F 찾기, Ctrl+P 인쇄 등)를 끈다 — 앱 단축키와 겹치지 않게
            #[cfg(all(windows, not(debug_assertions)))]
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.with_webview(|wv| unsafe {
                    use webview2_com::Microsoft::Web::WebView2::Win32::ICoreWebView2Settings3;
                    use windows::core::Interface;
                    if let Ok(core) = wv.controller().CoreWebView2() {
                        if let Ok(settings) = core.Settings() {
                            if let Ok(s3) = settings.cast::<ICoreWebView2Settings3>() {
                                let _ = s3.SetAreBrowserAcceleratorKeysEnabled(false);
                            }
                        }
                    }
                });
            }
            // 화면 쪽이 준비 신호를 못 보내도(오류 등) 창이 영영 안 뜨는 일이 없게
            let handle = app.handle().clone();
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_secs(3));
                if let Some(w) = handle.get_webview_window("main") {
                    if !w.is_visible().unwrap_or(true) {
                        let _ = w.show();
                    }
                }
            });
            Ok(())
        })
        .manage(pty::Ptys::default())
        .manage(watch::Watches::default())
        .invoke_handler(tauri::generate_handler![
            process::run_process,
            process::run_process_bytes,
            system::fs_read_base64,
            system::fs_write_temp,
            process::which,
            agents::external_agents,
            agents::bring_app_forward,
            pty::pty_spawn,
            pty::pty_write,
            pty::pty_resize,
            pty::pty_kill,
            watch::watch_start,
            watch::watch_stop,
            net::http_request,
            net::ci_job_log,
            net::http_image,
            net::resolve_host,
            system::secret_get,
            system::secret_set,
            system::fs_exists,
            system::fs_read_text,
            system::fs_read_head,
            system::fs_write_text,
            system::fs_list,
            system::fs_remove,
            system::fs_mkdirs,
            system::env_info,
            system::pick_folder,
            system::pick_file,
            system::open_url,
            system::reveal_path,
            system::open_terminal,
            system::open_console,
            system::open_html,
            system::open_rules,
            system::app_ready,
            launch::take_app_launches,
            local_projects::local_projects_read,
            local_projects::local_projects_write,
            update::update_check,
            update::update_install,
            update::update_verify,
            update::app_restart,
        ])
        .run(tauri::generate_context!())
        .expect("Couldn't start Gitrochi");
}
