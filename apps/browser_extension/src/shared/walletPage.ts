/** Only packaged wallet views may use private wallet-only operations. */
export function isWalletPage(url: string | undefined, extensionRoot: string): boolean {
  return url === `${extensionRoot}wallet.html` || url === `${extensionRoot}sidepanel.html` || isSidePanelDocument(url,extensionRoot);
}
export function isSidePanelDocument(url:string|undefined,extensionRoot:string):boolean {
  if(!url?.startsWith(`${extensionRoot}sidepanel.html?view=`))return false;
  return /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(url.slice(`${extensionRoot}sidepanel.html?view=`.length));
}
