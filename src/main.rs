use eframe::egui;
use std::{
    process::{Command, Stdio},
    sync::mpsc::{channel, Receiver, Sender},
    thread,
};

const SCRIPT: &str = "k3smanager.sh";

fn main() -> eframe::Result {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("K3s Manager")
            .with_inner_size([1120.0, 780.0]),
        ..Default::default()
    };
    eframe::run_native("K3s Manager", options, Box::new(|cc| Ok(Box::new(App::new(cc)))))
}

#[derive(Clone, Copy, PartialEq)]
enum Tab { Pods, Network, Audit, Help }

#[derive(Clone)]
struct Pod { id: usize, namespace: String, name: String }

struct App {
    tab: Tab,
    pods: Vec<Pod>,
    selected: Vec<usize>,
    output: String,
    tx: Sender<String>,
    rx: Receiver<String>,
    id_input: String,
    create_input: String,
    network_input: String,
    test_input: String,
    origin_input: String,
    destination_input: String,
}

impl App {
    fn new(_cc: &eframe::CreationContext<'_>) -> Self {
        let (tx, rx) = channel();
        let mut app = Self {
            tab: Tab::Pods,
            pods: vec![], selected: vec![], output: String::new(), tx, rx,
            id_input: String::new(), create_input: String::new(),
            network_input: String::new(), test_input: String::new(),
            origin_input: String::new(), destination_input: String::new(),
        };
        app.refresh_pods();
        app
    }

    fn append(&mut self, text: String) {
        self.output.push_str(&text);
        if !text.ends_with('\n') { self.output.push('\n'); }
    }

    fn run(&mut self, args: &[&str]) {
        let script = locate_script();
        let tx = self.tx.clone();
        let args = args.iter().map(|x| (*x).to_owned()).collect::<Vec<_>>();
        thread::spawn(move || {
            let result = Command::new("bash").arg(&script).args(&args)
                .stdout(Stdio::piped()).stderr(Stdio::piped()).spawn();
            match result {
                Ok(mut child) => {
                    use std::io::{BufRead, BufReader};
                    let stdout = child.stdout.take();
                    let stderr = child.stderr.take();
                    if let Some(out) = stdout {
                        for line in BufReader::new(out).lines().map_while(Result::ok) { let _ = tx.send(line); }
                    }
                    if let Some(err) = stderr {
                        for line in BufReader::new(err).lines().map_while(Result::ok) { let _ = tx.send(line); }
                    }
                    let _ = child.wait();
                }
                Err(e) => { let _ = tx.send(format!("Error: {e}")); }
            }
        });
    }

    fn refresh_pods(&mut self) {
        let tx = self.tx.clone();
        thread::spawn(move || {
            let result = Command::new("kubectl")
                .args(["get", "pods", "--all-namespaces", "--no-headers", "-o",
                    "custom-columns=NS:.metadata.namespace,NAME:.metadata.name"])
                .output();
            match result {
                Ok(out) => {
                    let text = String::from_utf8_lossy(&out.stdout);
                    let mut count = 0usize;
                    let mut rows = String::new();
                    for line in text.lines() {
                        let mut parts = line.split_whitespace();
                        if let (Some(ns), Some(name)) = (parts.next(), parts.next()) {
                            if ns != "kube-system" { count += 1; rows.push_str(&format!("{ns}\t{name}\n")); }
                        }
                    }
                    let _ = tx.send(format!("PODS_UPDATE:{count}:"));
                    let _ = tx.send(format!("PODS_DATA:{rows}"));
                }
                Err(e) => { let _ = tx.send(format!("[Error] kubectl unavailable: {e}")); }
            }
        });
    }

    fn clear_output(&mut self) { self.output.clear(); }
}

fn locate_script() -> String {
    let candidates = ["k3smanager.sh", "/usr/local/bin/k3smanager.sh"];
    candidates.iter().find(|p| std::path::Path::new(p).exists())
        .unwrap_or(&"k3smanager.sh").to_string()
}

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        while let Ok(message) = self.rx.try_recv() {
            if let Some(rest) = message.strip_prefix("PODS_UPDATE:") {
                let _ = rest.split(':').next().unwrap_or("0").parse::<usize>();
            } else if let Some(data) = message.strip_prefix("PODS_DATA:") {
                self.pods.clear();
                for (id, line) in data.lines().enumerate() {
                    let mut parts = line.split('\t');
                    if let (Some(ns), Some(name)) = (parts.next(), parts.next()) {
                        self.pods.push(Pod { id: id + 1, namespace: ns.to_string(), name: name.to_string() });
                    }
                }
            } else { self.append(message); }
        }

        egui::TopBottomPanel::top("nav").show(ctx, |ui| {
            ui.horizontal(|ui| {
                if ui.button("📦 Pods").clicked() { self.tab = Tab::Pods; }
                if ui.button("🌐 Network").clicked() { self.tab = Tab::Network; }
                if ui.button("🛡️ Audit").clicked() { self.tab = Tab::Audit; }
                if ui.button("📖 Help").clicked() { self.tab = Tab::Help; }
                if ui.button("💻 TERM").clicked() {
                    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/bash".into());
                    for terminal in ["x-terminal-emulator", "gnome-terminal", "konsole", "xfce4-terminal", "xterm"] {
                        let args = if terminal == "gnome-terminal" { vec!["--", shell.as_str()] } else { vec!["-e", shell.as_str()] };
                        if Command::new(terminal).args(args).spawn().is_ok() { break; }
                    }
                }
            });
        });

        egui::CentralPanel::default().show(ctx, |ui| {
            match self.tab {
                Tab::Pods => {
                    ui.horizontal(|ui| {
                        if ui.button("🔄 Refresh").clicked() { self.refresh_pods(); }
                        if ui.button("📜 Logs").clicked() {
                            if let Some(p) = self.selected.first().and_then(|id| self.pods.iter().find(|x| x.id == *id)) {
                                self.run(&["logs", &p.name]);
                            }
                        }
                        if ui.button("🔍 Describe").clicked() {
                            if let Some(p) = self.selected.first().and_then(|id| self.pods.iter().find(|x| x.id == *id)) {
                                self.run(&["describe", &p.name]);
                            }
                        }
                        if ui.button("🗑 Delete").clicked() {
                            for id in self.selected.clone() {
                                if let Some(p) = self.pods.iter().find(|x| x.id == id) {
                                    self.run(&["delete-pod", &p.name, &p.namespace]);
                                }
                            }
                        }
                    });
                    egui::ScrollArea::vertical().max_height(360.0).show(ui, |ui| {
                        egui::Grid::new("pods").striped(true).show(ui, |ui| {
                            ui.strong("ID"); ui.strong("Namespace"); ui.strong("Pod"); ui.end_row();
                            for pod in &self.pods {
                                let mut selected = self.selected.contains(&pod.id);
                                if ui.checkbox(&mut selected, "").changed() {
                                    if selected { self.selected.push(pod.id); } else { self.selected.retain(|x| *x != pod.id); }
                                }
                                ui.label(&pod.namespace); ui.label(&pod.name); ui.end_row();
                            }
                        });
                    });
                    ui.separator();
                    ui.horizontal(|ui| {
                        ui.label("IDs / range:"); ui.text_edit_singleline(&mut self.id_input);
                        if ui.button("Add").clicked() { self.run(&["select", &self.id_input]); }
                        if ui.button("Remove").clicked() { self.run(&["remove", &self.id_input]); }
                        if ui.button("IP").clicked() { self.run(&["ip", &self.id_input]); }
                    });
                    ui.horizontal(|ui| {
                        ui.label("Create:"); ui.text_edit_singleline(&mut self.create_input);
                        if ui.button("Create pods").clicked() { self.run(&["create", &self.create_input]); }
                    });
                }
                Tab::Network => {
                    ui.horizontal(|ui| {
                        ui.label("Pod ID / range:"); ui.text_edit_singleline(&mut self.network_input);
                        if ui.button("Scan ports").clicked() { self.run(&["check-ports", &self.network_input]); }
                        if ui.button("Close ports").clicked() { self.run(&["close-port", &self.network_input]); }
                        if ui.button("Open ports").clicked() { self.run(&["open-port", &self.network_input]); }
                    });
                    ui.horizontal(|ui| {
                        ui.label("Test network:"); ui.text_edit_singleline(&mut self.test_input);
                        if ui.button("Run test").clicked() { self.run(&["test-network", &self.test_input]); }
                    });
                    ui.horizontal(|ui| {
                        ui.label("Origin:"); ui.text_edit_singleline(&mut self.origin_input);
                        ui.label("Destination:"); ui.text_edit_singleline(&mut self.destination_input);
                        if ui.button("Test traffic").clicked() { self.run(&["test-connections", &self.origin_input, &self.destination_input]); }
                    });
                }
                Tab::Audit => {
                    if ui.button("Monitor connections").clicked() { self.run(&["monitor-connect"]); }
                    ui.separator();
                    if ui.button("Check version").clicked() { self.run(&["version"]); }
                    if ui.button("Update manager").clicked() { self.run(&["update"]); }
                }
                Tab::Help => {
                    egui::ScrollArea::vertical().show(ui, |ui| {
                        ui.label("K3s Manager commands");
                        ui.monospace("list [ID|N-M|namespace]  select <IDs>  remove <IDs>  clear-sel");
                        ui.monospace("ip <ID|name> [namespace]  describe [-l]  logs  delete");
                        ui.monospace("create <N|N-M> [-i image]  check-ports  close-port  open-port");
                        ui.monospace("test-network [N|N-M|-a]  test-connections <origin> <dest>");
                        ui.monospace("monitor-connect  version  update  help  exit");
                        ui.separator();
                        ui.hyperlink_to("GitHub: braispm9", "https://github.com/braispm9");
                        ui.hyperlink_to("GitHub: pwnddev", "https://github.com/pwnddev");
                    });
                }
            }

            ui.separator();
            ui.horizontal(|ui| {
                ui.strong("Terminal output");
                if ui.button("Clear").clicked() { self.clear_output(); }
            });
            egui::ScrollArea::vertical().stick_to_bottom(true).show(ui, |ui| {
                ui.add(egui::TextEdit::multiline(&mut self.output)
                    .font(egui::TextStyle::Monospace).desired_rows(10).interactive(false));
            });
        });
        ctx.request_repaint_after(std::time::Duration::from_millis(100));
    }
}
