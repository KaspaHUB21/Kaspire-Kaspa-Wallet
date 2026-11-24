declare global {
  interface Window {
    KasHubAndroid?: AndroidDownloadBridge;
    Android?: AndroidDownloadBridge;
  }
}

interface AndroidDownloadBridge {
  saveTextFile?: (filename: string, content: string, mimeType: string) => void;
  saveTextFileBase64?: (filename: string, base64Content: string, mimeType: string) => void;
}

const ANDROID_EXPORT_PROMPT_PREFIX = "KASHUB_EXPORT:";

function toBase64Utf8(value: string) {
  const bytes = new TextEncoder().encode(value);
  let binary = "";
  for (let index = 0; index < bytes.length; index += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  }
  return btoa(binary);
}

export function downloadText(filename: string, content: string, type: string) {
  const base64Content = toBase64Utf8(content);
  const androidBridge = window.KasHubAndroid || window.Android;
  if (androidBridge?.saveTextFileBase64) {
    androidBridge.saveTextFileBase64(filename, base64Content, type);
    return;
  }
  if (androidBridge?.saveTextFile) {
    androidBridge.saveTextFile(filename, content, type);
    return;
  }
  if (navigator.userAgent.includes("KasHubAndroid")) {
    window.prompt(ANDROID_EXPORT_PROMPT_PREFIX + JSON.stringify({ filename, mimeType: type, base64Content }), "");
    return;
  }

  const blob = new Blob([content], { type });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  link.click();
  URL.revokeObjectURL(url);
}

