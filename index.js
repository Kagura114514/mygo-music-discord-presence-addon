let presenceProcess = null;

function startPresence() {
  if (host.platform !== "windows" || presenceProcess) return;
  const clientId = String(host.setting("discordClientId") || "").trim();
  if (!/^\d{17,20}$/.test(clientId)) {
    return "请先在插件设置中填写 Discord Application ID。";
  }
  try {
    presenceProcess = host.spawn("powershell.exe", [
      "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
      "-WindowStyle", "Hidden", "-File", `${host.dir}\\discord-presence.ps1`, clientId,
    ]);
    const child = presenceProcess;
    Promise.resolve(child.wait()).then(
      () => { if (presenceProcess === child) presenceProcess = null; },
      () => { if (presenceProcess === child) presenceProcess = null; },
    );
    return "已启动后台同步。现在可切回原来的网易云来源播放；状态同步会继续运行。";
  } catch (error) {
    presenceProcess = null;
    return `后台同步启动失败：${error?.message || error}`;
  }
}

export function home() {
  const message = startPresence();
  return {
    title: "Discord 状态同步",
    subtitle: message || "后台同步已运行。播放 MyGo 中的音乐时会更新 Discord 活动。",
    description: "启动后可切回其他音乐来源。关闭 MyGo 或停用本插件会结束后台同步。",
    sections: [],
  };
}
