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
function notesWiki(source, path, owner, profile = {}, metadata = {}, turnCount = 0) {
  const template = document.createElement('template'); template.innerHTML = source;
  const sections = [...template.content.children];
  if (sections.length !== 3 || sections.some((s,i) => s.tagName !== 'SECTION' || s.id !== ['about','map','content'][i]))
    throw new Error('Notes.html requires exactly three sections: about, map, content.');
  const ids = [...template.content.querySelectorAll('[id]')].map(node => node.id);
  if (new Set(ids).size !== ids.length) throw new Error('Notes.html section anchors must be unique.');
  const root = document.createElement('div'); root.className = 'notes-wiki';
  const tags = new Set('section article nav div p span h2 h3 h4 blockquote sup sub pre code a img table thead tbody tfoot tr td th caption ul ol li dl dt dd details summary figure figcaption strong em b i small br hr'.split(' '));
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
    const classes = (node.getAttribute('class') || '').split(/\s+/).filter(name => ['citation','permalink','references','origin','backref','wiki-table','file-list','stub-note','draft-note'].includes(name));
    if (classes.length) element.className = classes.join(' ');
    for (const attr of ['data-memo-name','data-memo-role','data-memo-assists'])
      if (node.hasAttribute(attr)) element.setAttribute(attr,node.getAttribute(attr));
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
        element.src = '/api/' + (profile.kind==='group'?'groups':'agents') + '/' + encodeURIComponent(owner) + '/notes?image=' + encodeURIComponent(src);
    }
    for (const attr of ['colspan','rowspan']) if (/^[1-9]\d?$/.test(node.getAttribute(attr) || '')) element.setAttribute(attr,node.getAttribute(attr));
    element.append(...[...node.childNodes].map(copy)); return element;
  }
  root.append(...sections.map(copy));
  presentMemo(root, profile, {path, ...metadata}, turnCount);
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
// Older wikis contain YAML facts. Render only the conservative, line-based form;
// unfamiliar syntax remains a highlighted snippet, with its text intact.
function memoFacts(code) {
  const lines = code.textContent.trim().split('\n');
  if (!lines.length || !lines.every(line => !line.trim() || /^\s*(?:[\w-]+\s*:|[-#] |[ \t]+\S)/.test(line))) return null;
  const fragment = document.createElement('div'); fragment.className = 'memo-facts';
  const scalar = value => {
    try { const parsed = JSON.parse(value); if (typeof parsed === 'string') return parsed; } catch {}
    return value;
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i], match = /^(\s*)([\w-]+):\s*(.*)$/.exec(line);
    const p = document.createElement('p');
    if (match) {
      const label = match[2].replace(/_/g,' '), value = match[3];
      const strong = document.createElement('strong'); strong.textContent = label + ': ';
      p.append(strong);
      if (/^[|>][+-]?$/.test(value)) {
        const block = [];
        while (i + 1 < lines.length && (!lines[i+1].trim() || lines[i+1].match(/^\s*/)[0].length > match[1].length)) block.push(lines[++i].trim());
        p.append(document.createTextNode(block.join(value[0] === '>' ? ' ' : '\n')));
      } else p.append(document.createTextNode(scalar(value)));
    } else p.textContent = line.trim();
    fragment.append(p);
  }
  return fragment;
}
function presentMemo(root, profile, metadata, turnCount) {
  const about = root.querySelector('#note-about'), map = root.querySelector('#note-map'), content = root.querySelector('#note-content');
  const displayName = about.dataset.memoName || profile.name || 'Sapi';
  const label = id => id.replace(/^note-/, '').replace(/[-_]/g,' ').replace(/^./, c=>c.toUpperCase());
  const empty = node => {
    const snippets = [...node.querySelectorAll('pre > code')];
    return snippets.length > 0 && snippets.every(code => code.textContent.trim().split('\n').every(line => !line.trim() || /^\s*[\w-]+:\s*(?:["']?\*\*\*["']?|\{\}|\[\])\s*$/.test(line))) &&
      !node.querySelector('img,a,p,table,blockquote');
  };
  const emptyIds = new Set();
  content.querySelectorAll('article,details').forEach(node => {
    if (!empty(node)) return;
    [node,...node.querySelectorAll('[id]')].forEach(child => {if(child.id) emptyIds.add(child.id);});
    node.remove();
  });
  // Preserve links into unrecorded fields as one compact empty-memory section.
  if (emptyIds.size) {
    const stub = document.createElement('aside'); stub.className = 'memo-unrecorded';
    stub.textContent = 'Unrecorded fields have no saved content yet.';
    for (const id of emptyIds) { const anchor = document.createElement('span'); anchor.id = id; stub.append(anchor); }
    content.append(stub);
  }
  root.querySelectorAll('details').forEach(node => {
    const section = document.createElement('div'); section.id = node.id;
    section.append(...node.childNodes); node.replaceWith(section);
  });
  root.querySelectorAll('summary').forEach(node => {
    const heading = document.createElement('h3'); heading.textContent = node.textContent; node.replaceWith(heading);
  });
  root.querySelectorAll('pre > code[data-language="yaml"]').forEach(code => {
    const facts = memoFacts(code); if (facts) code.parentElement.replaceWith(facts);
  });
  // The about section is the article lead. Avoid repeating schema labels there.
  about.querySelectorAll('.memo-facts strong').forEach(node => node.remove());
  const named = new Map([...map.querySelectorAll('[data-note-anchor]')].map(a=>[a.dataset.noteAnchor,a.textContent]));
  for (const article of content.querySelectorAll(':scope > article')) {
    if (!article.querySelector(':scope > h2')) {
      const h2 = document.createElement('h2'); h2.textContent = named.get(article.id) || label(article.id); article.prepend(h2);
    }
  }
  const toc = document.createElement('nav'); toc.id = map.id; toc.className = 'memo-toc'; toc.setAttribute('aria-label','Contents');
  const list = document.createElement('ol'), seen = new Set();
  const entries = [...content.querySelectorAll('h2')].map(h => ({id:h.id || h.parentElement.id,text:[...h.childNodes].filter(n=>n.nodeType===3 || !n.classList?.contains('permalink')).map(n=>n.textContent).join('')}));
  const links = entries.length ? entries : [...map.querySelectorAll('[data-note-anchor]')].map(a => ({id:a.dataset.noteAnchor,text:a.textContent}));
  for (const entry of links) {
    if (!entry.id || emptyIds.has(entry.id) || seen.has(entry.id) || !root.querySelector('#'+entry.id)) continue;
    seen.add(entry.id);
    const li = document.createElement('li'), a = document.createElement('a');
    a.href = '#'+entry.id; a.dataset.noteAnchor = entry.id; a.textContent = entry.text; li.append(a); list.append(li);
  }
  if (list.children.length > 1) { const title = document.createElement('strong'); title.textContent = 'Contents'; toc.append(title,list); map.replaceWith(toc); }
  else map.remove();
  const header = document.createElement('header'); header.className = 'memo-header';
  const title = document.createElement('h1'); title.textContent = 'Memo'; header.append(title);
  const dates = document.createElement('p'); dates.className = 'memo-meta';
  function history(label, date, author) {
    const row = document.createElement('span');
    row.append(document.createTextNode(label+' '));
    if (date && !Number.isNaN(Date.parse(date))) {
      const time = document.createElement('time'); time.dateTime = date;
      const value = new Date(date);
      const dateText = value.toLocaleDateString('en-GB',{day:'numeric',month:'short',year:'numeric'});
      const timeText = value.toLocaleTimeString('en-GB',{hour:'2-digit',minute:'2-digit',hour12:false});
      const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
      const zoneText = zone === 'Asia/Dubai' ? 'GST' : value.toLocaleTimeString('en-GB',{timeZoneName:'short'}).split(' ').pop();
      time.textContent = dateText+' · '+timeText+' '+zoneText; row.append(time);
    } else row.append(document.createTextNode('not recorded'));
    row.append(document.createTextNode(' by '));
    const by = document.createElement('span'); by.className = 'memo-actor'; by.textContent = author || 'unrecorded actor'; row.append(by); dates.append(row);
  }
  history('Last modified at',metadata.modified_at,metadata.modified_by);
  history('Created at',metadata.created_at,metadata.created_by);
  header.append(dates); root.prepend(header);
  const box = document.createElement('aside'); box.className = 'memo-infobox'; box.setAttribute('aria-label',displayName+' at a glance');
  const identity = document.createElement('div'); identity.className = 'memo-identity';
  const face = document.createElement('span'); face.className = 'memo-avatar'; face.textContent = '('+(profile.face || '◠‿◠')+')';
  face.style.backgroundColor = /^#[a-f0-9]{6}$/i.test(profile.color) ? profile.color : '#d8e5f4';
  const name = document.createElement('strong'); name.textContent = displayName; identity.append(face,name); box.append(identity);
  const table = document.createElement('table');
  for (const [key,value] of [['Full name',displayName !== profile.name ? profile.name : null],['Role',about.dataset.memoRole || profile.role],['Assists',about.dataset.memoAssists],['History',turnCount+' recorded turns'],[profile.kind==='group'?'Group ID':'Sapi ID',profile.id]]) {
    if (!value) continue;
    const tr = document.createElement('tr'), th = document.createElement('th'), td = document.createElement('td');
    th.textContent = key; td.textContent = value; if (key.endsWith(' ID')) td.className = 'memo-id'; tr.append(th,td); table.append(tr);
  }
  box.append(table);
  const workspace = document.createElement('div'); workspace.className = 'memo-workspace';
  const workspaceLabel = document.createElement('strong'); workspaceLabel.textContent = 'Workspace';
  const workspacePath = document.createElement('code'); workspacePath.textContent = metadata.workspace || metadata.path?.replace(/\/[^/]+$/,'') || 'Not recorded';
  workspace.append(workspaceLabel,workspacePath); box.append(workspace); about.prepend(box); about.className = 'memo-lead';
  if (!content.querySelector('article,h2,h3,p,pre,table,img')) {
    const p = document.createElement('p'); p.className = 'memo-stub'; p.textContent = 'This Memo is a stub. No populated memory entries have been saved yet.'; content.prepend(p);
  }
}
function notesInfo(id) {return agent(id).kind==='group'?agent(id).notes:live.orchestration[id].notes;}
function renderNotes(host) {
  const id = state.selected, info = notesInfo(id), profile = agent(id);
  const turns = live.turns.filter(turn => profile.kind==='group'?turn.group===id:turn.agent===id).length;
  const key = JSON.stringify([id,info.revision,profile.name,profile.role,profile.face,profile.color,turns]);
  if (host.dataset.notes === key && host.querySelector('.notes-wiki')) return;
  if (host.dataset.notesPending === key) return;
  const previousScroll = host.dataset.notesOwner === id ? host.querySelector('.notes-wiki')?.scrollTop || 0 : 0;
  if (!host.querySelector('.notes-wiki') || host.dataset.notesOwner !== id) host.replaceChildren();
  host.dataset.notesPending = key; host.dataset.notesOwner = id;
  api('/api/' + (profile.kind==='group'?'groups':'agents') + '/' + id + '/notes').then(row => {
    if (state.selected !== id || !['notes','work'].includes(state.panel) || !host.isConnected || notesInfo(id).revision !== info.revision || host.dataset.notesPending !== key) return;
    host.replaceChildren(notesWiki(row.content, row.path, id, profile, row.metadata || info, turns)); host.dataset.notes = key;
    host.querySelector('.notes-wiki').scrollTop = previousScroll;
  }).catch(error => {if (state.selected === id && ['notes','work'].includes(state.panel) && host.dataset.notesPending === key) host.textContent = error.message;})
    .finally(() => {if (host.dataset.notesPending === key) delete host.dataset.notesPending;});
}
