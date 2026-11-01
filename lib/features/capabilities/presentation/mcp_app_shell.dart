import 'dart:convert';

/// A trusted native bridge, cross-origin proxy and opaque source frame. Source
/// HTML never receives the native bridge nonce, API URL or authorization headers.
class McpAppShell {
  McpAppShell({required String html, required String nonce}) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(nonce)) {
      throw ArgumentError('Invalid view nonce');
    }
    if (utf8.encode(html).length > 2 * 1024 * 1024) {
      throw ArgumentError('App resource exceeds 2 MiB');
    }
    proxyUrl = 'data:text/html;base64,${base64Encode(utf8.encode(_proxy))}';
    final spec = jsonEncode({
      'html': html,
      'nonce': nonce,
      'proxy': proxyUrl,
    }).replaceAll('<', r'\u003c');
    document =
        '''<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; frame-src data: about:; object-src 'none'; base-uri 'none'; form-action 'none'"><style>html,body,iframe{margin:0;border:0;width:100%;height:100%;background:transparent}iframe{display:block}</style></head><body><iframe id="proxy" sandbox="allow-scripts allow-same-origin" referrerpolicy="no-referrer"></iframe><script>const spec=$spec;$_host</script></body></html>''';
  }
  late final String document, proxyUrl;
  bool allowsNavigation(String url) =>
      url == 'about:blank' || url == 'about:srcdoc' || url == proxyUrl;

  static const _host = r'''
const proxy=document.getElementById('proxy');
window.xiaoqiAppDeliver=message=>proxy.contentWindow.postMessage(message,'*');
window.addEventListener('message',event=>{
 if(event.source!==proxy.contentWindow||!event.data||event.data.jsonrpc!=='2.0')return;
 if(event.data.method==='ui/notifications/sandbox-proxy-ready'){
  proxy.contentWindow.postMessage({jsonrpc:'2.0',method:'ui/notifications/sandbox-resource-ready',params:{html:spec.html}},'*');return;
 }
 if((event.data.method||'').startsWith('ui/notifications/sandbox-'))return;
 const message=JSON.stringify({nonce:spec.nonce,rpc:event.data});
 if(message.length<=131072)XiaoqiMcpApp.postMessage(message);
});
proxy.src=spec.proxy;
''';
  static const _proxy =
      r'''<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; frame-src about:; object-src 'none'; base-uri 'none'; form-action 'none'"><style>html,body,iframe{margin:0;border:0;width:100%;height:100%}iframe{display:block}</style></head><body><iframe id="view" sandbox="allow-scripts" referrerpolicy="no-referrer"></iframe><script>
const view=document.getElementById('view');
window.addEventListener('message',event=>{
 if(!event.data||event.data.jsonrpc!=='2.0')return;
 if(event.source===window.parent){
  if(event.data.method==='ui/notifications/sandbox-resource-ready'){
   const doc=new DOMParser().parseFromString(event.data.params.html,'text/html');
   const policy=doc.createElement('meta');policy.httpEquiv='Content-Security-Policy';
   policy.content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";
   doc.head.prepend(policy);
   doc.querySelectorAll('[autofocus]').forEach(element=>element.removeAttribute('autofocus'));
   const focus=doc.createElement('script');
   focus.textContent=`document.addEventListener('pointerdown',event=>{const active=document.activeElement;if(active&&active!==event.target&&active.matches('input,textarea,[contenteditable]')&&!event.target.closest('input,textarea,[contenteditable]'))active.blur();},true);let previous=window.visualViewport?.height||window.innerHeight;window.visualViewport?.addEventListener('resize',()=>{const height=window.visualViewport.height;const active=document.activeElement;if(height>previous+60&&active&&active.matches('input,textarea')&&!active.value)active.blur();previous=height;});`;
   doc.head.append(focus);
   view.srcdoc='<!doctype html>'+doc.documentElement.outerHTML;return;
  }
  if(!(event.data.method||'').startsWith('ui/notifications/sandbox-'))view.contentWindow.postMessage(event.data,'*');
 }else if(event.source===view.contentWindow){
  if(!(event.data.method||'').startsWith('ui/notifications/sandbox-'))window.parent.postMessage(event.data,'*');
 }
});
window.parent.postMessage({jsonrpc:'2.0',method:'ui/notifications/sandbox-proxy-ready'},'*');
</script></body></html>''';
}
