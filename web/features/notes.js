function highlightNotes(text, language = 'yaml') {
  if (language === 'yaml' && /[|>][1-9+-]*\s*(?:#.*)?$/m.test(text)) {
    let blockIndent = null;
    return text.split('\n').map(line => {
      const indent = line.match(/^ */)[0].length;
      if (blockIndent !== null && (!line.trim() || indent > blockIndent)) return '<span class="syntax-string">' + esc(line) + '</span>';
      blockIndent = /[|>][1-9+-]*\s*(?:#.*)?$/.test(line) ? indent + (/^\s*-\s/.test(line) ? 2 : 0) : null;
      return highlightNotes(line, 'yaml-line');
    }).join('\n');
  }
  const patterns = {
    yaml: /(?<string>"(?:\\.|[^"\\])*"|'(?:''|[^'])*')|(?<comment>(?<!\S)#[^\n]*)|(?<key>\b[A-Za-z_][\w-]*(?=:\s|:$))|(?<literal>\b(?:true|false|null|\d+(?:\.\d+)?)\b)|(?<punctuation>[{}[\]:,|>])/gm,
    python: /(?<string>"""[\s\S]*?"""|'''[\s\S]*?'''|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(?<comment>#[^\n]*)|(?<keyword>\b(?:def|class|import|from|as|return|if|elif|else|for|while|in|is|not|and|or|with|try|except|raise|yield|async|await|pass|lambda)\b)|(?<literal>\b(?:True|False|None|\d+(?:\.\d+)?)\b)/g,
    haskell: /(?<string>"(?:\\.|[^"\\])*")|(?<comment>--[^\n]*|\{-[\s\S]*?-\})|(?<keyword>\b(?:data|type|newtype|where|let|in|case|of|if|then|else|do|module|import|deriving)\b|::|->|<-|=>)|(?<literal>\b(?:[A-Z]\w*|\d+)\b)/g,
    html: /(?<comment><!--[\s\S]*?-->)|(?<string>"[^"]*"|'[^']*')|(?<keyword><\/?[\w-]+|\/?>)|(?<key>\b[\w-]+(?=\s*=))/g
  };
  const pattern = patterns[language === 'svg' ? 'html' : language === 'yaml-line' ? 'yaml' : language];
  if (!pattern) return esc(text);
  let output = '', cursor = 0;
  for (const match of text.matchAll(pattern)) {
    const kind = Object.keys(match.groups).find(key => match.groups[key] !== undefined);
    output += esc(text.slice(cursor, match.index)) + '<span class="syntax-' + kind + '">' + esc(match[0]) + '</span>';
    cursor = match.index + match[0].length;
  }
  return output + esc(text.slice(cursor));
}
function notesWiki(source, path, owner) {
  const template = document.createElement('template'); template.innerHTML = source;
  const sections = [...template.content.children];
  if (sections.length !== 3 || sections.some((s,i) => s.tagName !== 'SECTION' || s.id !== ['about','map','content'][i]))
    throw new Error('Notes.html requires exactly three sections: about, map, content.');
  const ids = [...template.content.querySelectorAll('[id]')].map(node => node.id);
  if (new Set(ids).size !== ids.length) throw new Error('Notes.html section anchors must be unique.');
  const root = document.createElement('div'); root.className = 'notes-wiki';
  const tags = new Set('section article nav div p span pre code a img table thead tbody tfoot tr td th caption ul ol li dl dt dd details summary figure figcaption strong em b i small br hr'.split(' '));
  function copy(node) {
    if (node.nodeType === 3) return document.createTextNode(node.textContent);
    if (node.nodeType !== 1) return document.createTextNode('');
    const tag = node.localName;
    if (tag === 'svg') {
      const image = document.createElement('img');
      image.src = 'data:image/svg+xml,' + encodeURIComponent(new XMLSerializer().serializeToString(node));
      image.alt = node.getAttribute('aria-label') || 'Diagram'; return image;
    }
    if (!tags.has(tag)) return document.createTextNode('');
    const element = document.createElement(tag);
    if (tag === 'details') element.open = node.hasAttribute('open');
    if (/^[a-z][\w-]*$/i.test(node.id)) element.id = 'note-' + node.id;
    if (tag === 'code') {
      const language = /^language-(yaml|python|html|svg|haskell)$/.exec(node.className)?.[1] || 'text';
      element.dataset.language = language; element.innerHTML = highlightNotes(node.textContent, language); return element;
    }
    if (tag === 'a') {
      const href = node.getAttribute('href') || '';
      if (/^#[a-z][\w-]*$/i.test(href)) element.dataset.noteAnchor = 'note-' + href.slice(1);
      else {
        try {
          const url = new URL(href, 'file://' + path);
          if (url.protocol === 'file:') element.dataset.fileLink = decodeURIComponent(url.pathname);
          else if (['http:','https:'].includes(url.protocol)) {
            element.href = url.href; element.className = 'chat-link'; element.target = '_blank'; element.rel = 'noopener noreferrer';
          }
        } catch {}
      }
      if (element.dataset.noteAnchor || element.dataset.fileLink) {element.href = '#'; element.setAttribute('role','link');}
    }
    if (tag === 'img') {
      const src = node.getAttribute('src') || '';
      element.alt = node.getAttribute('alt') || '';
      if (/^data:image\/(?:png|jpeg|gif|webp|svg\+xml)[;,]/i.test(src)) element.src = src;
      else if (src && !/^(?:[a-z]+:|\/\/|\/)/i.test(src))
        element.src = '/api/agents/' + encodeURIComponent(owner) + '/notes?image=' + encodeURIComponent(src);
    }
    for (const attr of ['colspan','rowspan']) if (/^[1-9]\d?$/.test(node.getAttribute(attr) || '')) element.setAttribute(attr,node.getAttribute(attr));
    element.append(...[...node.childNodes].map(copy)); return element;
  }
  root.append(...sections.map(copy));
  root.querySelectorAll('pre > code').forEach(code => code.parentElement.dataset.language = code.dataset.language);
  root.addEventListener('click', event => {
    const link = event.target.closest('[data-note-anchor]');
    if (link) {
      event.preventDefault();
      const target = root.querySelector('#' + link.dataset.noteAnchor);
      for (let parent = target; parent && parent !== root; parent = parent.parentElement)
        if (parent.tagName === 'DETAILS') parent.open = true;
      target?.scrollIntoView({block:'start'});
    }
  });
  return root;
}
function renderNotes(host) {
  const id = state.selected, info = live.orchestration[id].notes, key = id + ':' + info.revision;
  if (host.dataset.notes === key && host.querySelector('.notes-wiki')) return;
  const previousScroll = host.querySelector('#note-content')?.scrollTop || 0;
  if (!host.querySelector('.notes-wiki') || !host.dataset.notes?.startsWith(id + ':')) host.replaceChildren();
  api('/api/agents/' + id + '/notes').then(row => {
    if (state.selected !== id || state.panel !== 'notes' || live.orchestration[id].notes.revision !== info.revision) return;
    host.replaceChildren(notesWiki(row.content, info.path, id)); host.dataset.notes = key;
    host.querySelector('#note-content').scrollTop = previousScroll;
  }).catch(error => {if (state.selected === id && state.panel === 'notes') host.textContent = error.message;});
}
