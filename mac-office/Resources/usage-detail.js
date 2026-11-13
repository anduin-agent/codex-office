(() => {
  'use strict';

  const copy = {
    heading: ['详细用量', 'Usage details'],
    from: ['开始日期', 'Start date'],
    to: ['结束日期', 'End date'],
    project: ['项目', 'Project'],
    model: ['模型', 'Model'],
    models: ['模型', 'Models'],
    allProjects: ['所有项目', 'All projects'],
    allModels: ['所有模型', 'All models'],
    unknownProject: ['未归属项目', 'Unassigned project'],
    unknownModel: ['未知模型', 'Unknown model'],
    reset: ['重置', 'Reset'],
    apply: ['应用筛选', 'Apply filters'],
    sessions: ['会话用量', 'Usage by session'],
    groupCount: ['个对话组', 'conversation groups'],
    oneGroup: ['个对话组', 'conversation group'],
    expandAll: ['全部展开', 'Expand all'],
    collapseAll: ['全部收起', 'Collapse all'],
    expandGroup: ['展开', 'Expand'],
    collapseGroup: ['收起', 'Collapse'],
    groupTokens: ['筛选范围内的合计 Token', 'Total tokens in the selected range'],
    groupTotal: ['主对话及子会话合计', 'Main chat and child sessions'],
    mainUsage: ['主对话自身', 'Main chat only'],
    subagent: ['子 Agent', 'Subagent'],
    guardian_review: ['自动审批', 'Automatic review'],
    unassigned_guardian: ['未归属的自动审批', 'Unassigned automatic reviews'],
    previous: ['上一页', 'Previous'],
    next: ['下一页', 'Next'],
    sessionDetail: ['会话详情', 'Session details'],
    close: ['收起', 'Close'],
    selectedTokens: ['筛选范围内的 Token', 'Tokens in the selected range'],
    dateRange: ['日期范围', 'Date range'],
    openChat: ['在 Codex 中打开', 'Open in Codex'],
    loading: ['正在读取本机 Codex 用量…', 'Reading local Codex usage…'],
    retry: ['仍在索引本机记录。可稍后再次应用筛选。', 'Local records are still being indexed. Apply the filters again in a moment.'],
    unavailable: ['暂时无法读取本机 Codex 用量。', 'Local Codex usage is temporarily unavailable.'],
    missingDate: ['请选择开始日期和结束日期。', 'Choose a start date and an end date.'],
    invalid: ['请确认开始日期不晚于结束日期。', 'Enter a start date on or before the end date.'],
    partial: ['部分日志暂时无法读取，显示已读到的用量。', 'Some logs are unavailable. Showing the usage read so far.'],
    empty: ['没有符合筛选条件的会话。', 'No sessions match these filters.'],
    untitled: ['未命名会话', 'Untitled session'],
    costNote: ['按 API 标价折算的名义费用（USD），不代表实际扣费。', 'Nominal cost at listed API rates (USD). This does not reflect actual charges.'],
    costUnavailable: ['暂无 API 费用估算', 'API cost estimate unavailable'],
    costPartial: ['仅对有定价明细的 Token 估算', 'Estimated only for tokens with pricing details']
  };

  const byId = id => document.getElementById(id);
  const fields = {
    from: byId('usage-from'),
    to: byId('usage-to'),
    project: byId('usage-project'),
    model: byId('usage-model')
  };
  const list = byId('usage-session-list');
  const toggleGroups = byId('usage-toggle-groups');
  const detail = byId('session-detail');
  const results = detail.parentElement;
  const status = byId('usage-status');
  const dateKey = date => [date.getFullYear(), date.getMonth() + 1, date.getDate()]
    .map((part, index) => String(part).padStart(index ? 2 : 4, '0')).join('-');
  const validDate = value => /^\d{4}-\d{2}-\d{2}$/.test(value);
  const validCount = value => Number.isSafeInteger(value) && value >= 0;
  const sessionID = /^[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}$/i;
  const unassignedID = 'unassigned-guardian';
  const pageSize = 100;
  const maxRetries = 20;
  let language = window.officeInitialLanguage === 'en' ? 'en' : 'zh-CN';
  const formatter = new Intl.NumberFormat('en-US');
  const dollars = new Intl.NumberFormat('en-US', {style:'currency', currency:'USD', maximumFractionDigits:4});
  const dateFormat = () => new Intl.DateTimeFormat(language, {dateStyle:'medium',timeZone:'UTC'});
  let dates = dateFormat();
  let request = 0;
  let timer = 0;
  let retries = 0;
  let selectedSession = '';
  let visible = true;
  let state = 'loading';
  let statusKey = 'loading';
  let activeFilters;
  let result;
  const groupExpansion = new Map();
  let defaultGroupExpanded = true;
  let renderedGroups = [];
  const rowTitle = row => row.kind === 'unassigned_guardian' ? t('unassigned_guardian')
    : row.kind === 'self' ? t('mainUsage') : row.title || t('untitled');

  const t = key => copy[key][language === 'en' ? 1 : 0];
  const number = value => validCount(value) ? formatter.format(value) : '—';
  const tokens = value => validCount(value) ? number(value) + ' tokens' : '—';
  const sessions = count => number(count) + ' ' + t(count === 1 ? 'oneGroup' : 'groupCount');

  function showCost(element, usage, count = usage?.tokens) {
    const amount = usage?.estimated_usd;
    const priced = usage?.priced_tokens;
    const known = validCount(count) && validCount(priced) && priced <= count &&
      (priced > 0 || count === 0) && Number.isFinite(amount) && amount >= 0;
    element.textContent = !known ? '—' : amount > 0 && amount < 0.0001
      ? '< ' + dollars.format(0.0001) : '≈ ' + dollars.format(amount);
    element.title = !known ? t('costUnavailable')
      : priced < count || usage.status === 'partial' ? t('costPartial') : t('costNote');
  }

  function defaultDates() {
    const today = new Date();
    const start = new Date(today);
    start.setDate(start.getDate() - 29);
    fields.from.value = dateKey(start);
    fields.to.value = dateKey(today);
  }

  function applyLanguage() {
    document.documentElement.lang = language;
    document.title = t('heading');
    for (const element of document.querySelectorAll('[data-text]')) {
      element.textContent = t(element.dataset.text);
    }
    window.officeDropdowns?.refresh();
  }

  function bridge(message) {
    const handler = window.webkit?.messageHandlers?.officeDetail;
    handler?.postMessage(message);
    return Boolean(handler);
  }

  function showStatus(next, key = next) {
    state = next;
    statusKey = key;
    status.dataset.state = state;
    status.textContent = key ? t(key) : '';
  }

  function optionChoices(select, values, all, unknown) {
    const previous = select.value;
    const first = new Option(t(all), '');
    first.dataset.text = all;
    const choices = new Map();
    for (const item of Array.isArray(values) ? values : []) {
      if (typeof item?.id !== 'string' || !item.id || typeof item.title !== 'string') continue;
      choices.set(item.id, item.id === '__unknown__' ? t(unknown) : item.title);
    }
    if (previous && !choices.has(previous)) {
      const title = previous === '__unknown__' ? t(unknown) : select.selectedOptions[0]?.label;
      choices.set(previous, title || previous);
    }
    select.replaceChildren(first, ...[...choices].map(([id, title]) => new Option(title, id)));
    select.value = previous;
  }

  function selectedRow() {
    return [...list.querySelectorAll('[data-session-key]')].find(row => row.dataset.sessionKey === selectedSession);
  }

  function closeDetail(focus = false) {
    const row = selectedRow();
    row?.setAttribute('aria-expanded', 'false');
    selectedSession = '';
    detail.hidden = true;
    results.removeAttribute('data-session-open');
    if (focus) row?.focus();
  }

  function showDetail(session, key, grouped, focus = true) {
    selectedRow()?.setAttribute('aria-expanded', 'false');
    selectedSession = key;
    selectedRow()?.setAttribute('aria-expanded', 'true');
    const title = byId('session-title');
    title.textContent = session.kind === 'self' ? session.title || t('mainUsage') : rowTitle(session);
    byId('session-token-label').textContent = t(grouped ? 'groupTokens' : 'selectedTokens');
    byId('session-tokens').textContent = tokens(session.tokens);
    showCost(byId('session-cost'), session);
    byId('session-date-range').textContent = dates.format(new Date(activeFilters.from)) + ' – ' +
      dates.format(new Date(activeFilters.to));
    byId('session-project').textContent = session.project || t('unknownProject');
    const modelField = byId('session-models');
    const modelTotals = Array.isArray(session.model_totals) ? session.model_totals
      .filter(item => typeof item?.title === 'string' && validCount(item.tokens)) : [];
    if (modelTotals.length) {
      const breakdown = document.createElement('ul');
      breakdown.className = 'model-totals';
      for (const model of modelTotals) {
        const item = document.createElement('li');
        const name = document.createElement('span');
        const amount = document.createElement('span');
        const count = document.createElement('span');
        const cost = document.createElement('small');
        name.textContent = model.title || t('unknownModel');
        amount.className = 'usage-amount';
        count.textContent = number(model.tokens);
        cost.className = 'usage-cost';
        showCost(cost, model);
        amount.append(count, cost);
        item.append(name, amount);
        breakdown.append(item);
      }
      modelField.replaceChildren(breakdown);
    } else {
      modelField.textContent = (session.models ?? []).join(', ') || t('unknownModel');
    }
    detail.hidden = false;
    byId('open-codex-session').hidden = !sessionID.test(session.id);
    results.setAttribute('data-session-open', '');
    if (focus) title.focus();
  }

  function rowButton(row, key, grouped = false) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'session-row';
    button.dataset.sessionId = row.id;
    button.dataset.sessionKey = key;
    button.setAttribute('aria-controls', 'session-detail');
    button.setAttribute('aria-expanded', 'false');
    const title = document.createElement('span');
    title.textContent = rowTitle(row);
    title.title = title.textContent;
    const meta = document.createElement('span');
    meta.className = 'meta';
    const kind = ['subagent', 'guardian_review'].includes(row.kind) ? t(row.kind) : '';
    const scope = grouped && row.kind !== 'unassigned_guardian' ? t('groupTotal') : kind;
    const models = (row.models ?? []).join(', ') || t('unknownModel');
    meta.textContent = [scope, row.project || t('unknownProject'), models].filter(Boolean).join(' · ');
    meta.title = meta.textContent;
    const amount = document.createElement('span');
    amount.className = 'usage-amount';
    const total = document.createElement('strong');
    total.textContent = number(row.tokens);
    const cost = document.createElement('small');
    cost.className = 'usage-cost';
    showCost(cost, row);
    amount.append(total, cost);
    button.append(title, meta, amount);
    button.addEventListener('click', () => showDetail(row, key, grouped));
    return button;
  }

  function renderToggleGroups() {
    toggleGroups.hidden = !renderedGroups.length;
    toggleGroups.textContent = t(renderedGroups.some(group => !group.children.hidden) ? 'collapseAll' : 'expandAll');
  }

  function setGroupExpanded(group, expanded) {
    group.toggle.setAttribute('aria-expanded', String(expanded));
    group.toggle.setAttribute('aria-label', t(expanded ? 'collapseGroup' : 'expandGroup') + ' ' + group.title);
    group.children.hidden = !expanded;
  }

  function closeHiddenDetail() {
    if (selectedRow()?.closest('.session-children[hidden]')) closeDetail();
  }

  function renderResults(data) {
    const rows = Array.isArray(data?.sessions) ? data.sessions.filter(item =>
      typeof item?.id === 'string' && (sessionID.test(item.id) ||
        (item.id === unassignedID && item.kind === 'unassigned_guardian'))) : [];
    const hasResult = Boolean(data);
    byId('usage-total-tokens').textContent = tokens(data?.total_tokens);
    showCost(byId('usage-total-cost'), data, data?.total_tokens);
    byId('usage-session-count').textContent = hasResult ? sessions(data.total_sessions) : '';
    const fragment = document.createDocumentFragment();
    const entries = new Map();
    renderedGroups = [];
    for (const [index, row] of rows.entries()) {
      const item = document.createElement('li');
      const children = Array.isArray(row.children) ? row.children.filter(child => sessionID.test(child?.id)) : [];
      const grouped = children.length > 0 || row.kind === 'unassigned_guardian';
      const button = rowButton(row, row.id, grouped);
      entries.set(row.id, {row, grouped});
      if (!children.length) item.append(button);
      else {
        const header = document.createElement('div');
        header.className = 'session-group-header';
        const toggle = document.createElement('button');
        toggle.type = 'button';
        toggle.className = 'session-group-toggle';
        toggle.dataset.groupId = row.id;
        const childList = document.createElement('ul');
        childList.className = 'session-children';
        childList.setAttribute('role', 'list');
        childList.id = 'usage-children-' + index;
        toggle.setAttribute('aria-controls', childList.id);
        const group = {id: row.id, title: rowTitle(row), toggle, children: childList};
        renderedGroups.push(group);
        setGroupExpanded(group, groupExpansion.get(row.id) ?? defaultGroupExpanded);
        toggle.addEventListener('click', () => {
          const expanded = childList.hidden;
          groupExpansion.set(row.id, expanded);
          setGroupExpanded(group, expanded);
          closeHiddenDetail();
          renderToggleGroups();
        });
        for (const child of children) {
          const childItem = document.createElement('li');
          const key = row.id + '/' + child.id;
          entries.set(key, {row: child, grouped: false});
          childItem.append(rowButton(child, key));
          childList.append(childItem);
        }
        header.append(toggle, button);
        item.append(header, childList);
      }
      fragment.append(item);
    }
    const focusedSession = document.activeElement?.dataset.sessionKey;
    const focusedGroup = document.activeElement?.dataset.groupId;
    list.replaceChildren(fragment);
    const selected = entries.get(selectedSession);
    if (selected && !selectedRow()?.closest('.session-children[hidden]')) {
      showDetail(selected.row, selectedSession, selected.grouped, false);
    } else closeDetail();
    if (focusedSession) {
      [...list.querySelectorAll('[data-session-key]')].find(row => row.dataset.sessionKey === focusedSession)?.focus();
    }
    if (focusedGroup) renderedGroups.find(group => group.id === focusedGroup)?.toggle.focus();
    renderToggleGroups();
    const offset = activeFilters?.offset ?? 0;
    const totalSessions = data?.total_sessions ?? 0;
    byId('usage-pagination').hidden = totalSessions <= pageSize && offset === 0;
    byId('usage-page-range').textContent = number(rows.length ? offset + 1 : 0) + '–' +
      number(offset + rows.length) + ' / ' + number(totalSessions);
    byId('usage-previous').disabled = offset === 0;
    byId('usage-next').disabled = offset + rows.length >= totalSessions;
  }

  function sendQuery() {
    clearTimeout(timer);
    if (!activeFilters || !visible) return;
    showStatus('loading');
    byId('usage-previous').disabled = byId('usage-next').disabled = true;
    if (!bridge({action: 'query', request: ++request, ...activeFilters})) showStatus('unavailable');
  }

  function applyFilters() {
    clearTimeout(timer);
    const filters = Object.fromEntries(Object.entries(fields).map(([key, field]) => [key, field.value]));
    const {from, to} = filters;
    if (!activeFilters || Object.entries(filters).some(([key, value]) => value !== activeFilters[key])) {
      groupExpansion.clear();
      defaultGroupExpanded = true;
    }
    closeDetail();
    result = null;
    renderResults(null);
    const missingDate = !validDate(from) || !validDate(to);
    if (missingDate || from > to) {
      activeFilters = null;
      request++;
      showStatus('invalid', missingDate ? 'missingDate' : 'invalid');
      return;
    }
    retries = 0;
    activeFilters = {...filters, offset: 0};
    sendQuery();
  }

  function changePage(delta) {
    if (!activeFilters || state === 'loading') return;
    activeFilters.offset = Math.max(0, activeFilters.offset + delta * pageSize);
    retries = 0;
    closeDetail();
    sendQuery();
  }

  window.officeDetailReceiveUsage = (data, sequence) => {
    if (sequence !== request || !activeFilters) return;
    if (data?.status === 'loading') {
      showStatus('loading', retries >= maxRetries ? 'retry' : 'loading');
      if (visible && retries < maxRetries) {
        retries++;
        timer = setTimeout(sendQuery, 1500);
      }
      return;
    }
    const next = data?.status;
    if (next !== 'ok' && next !== 'partial') {
      result = null;
      renderResults(null);
      showStatus(next === 'invalid' ? next : 'unavailable');
      return;
    }
    if (activeFilters.offset > 0 && validCount(data.total_sessions) && data.total_sessions <= activeFilters.offset) {
      activeFilters.offset = Math.floor(Math.max(0, data.total_sessions - 1) / pageSize) * pageSize;
      sendQuery();
      return;
    }
    result = data;
    optionChoices(fields.project, data.projects, 'allProjects', 'unknownProject');
    optionChoices(fields.model, data.models, 'allModels', 'unknownModel');
    window.officeDropdowns?.refresh();
    renderResults(data);
    showStatus(next, next === 'partial' ? 'partial' : data.total_sessions === 0 ? 'empty' : '');
  };

  window.officeDetailSetLanguage = next => {
    const resolved = next === 'en' ? 'en' : 'zh-CN';
    if (language === resolved) return;
    language = resolved;
    dates = dateFormat();
    applyLanguage();
    if (result && state !== 'loading') renderResults(result);
    showStatus(state, statusKey);
    if (activeFilters) sendQuery();
  };
  window.officeDetailSetVisible = value => {
    visible = Boolean(value);
    if (!visible) clearTimeout(timer);
  };
  window.officeDetailRefresh = () => {
    retries = 0;
    if (activeFilters) sendQuery();
  };

  byId('usage-filter').addEventListener('submit', event => {
    event.preventDefault();
    applyFilters();
  });
  byId('usage-reset').addEventListener('click', () => {
    defaultDates();
    fields.project.value = fields.model.value = '';
    window.officeDropdowns?.refresh();
    applyFilters();
  });
  byId('usage-previous').addEventListener('click', () => changePage(-1));
  byId('usage-next').addEventListener('click', () => changePage(1));
  toggleGroups.addEventListener('click', () => {
    defaultGroupExpanded = renderedGroups.every(group => group.children.hidden);
    groupExpansion.clear();
    for (const group of renderedGroups) setGroupExpanded(group, defaultGroupExpanded);
    closeHiddenDetail();
    renderToggleGroups();
  });
  byId('close-session-detail').addEventListener('click', () => closeDetail(true));
  byId('open-codex-session').addEventListener('click', () => {
    const id = selectedRow()?.dataset.sessionId;
    if (id && sessionID.test(id)) bridge({action: 'openChat', id});
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && !detail.hidden) {
      event.preventDefault();
      closeDetail(true);
    }
  });

  defaultDates();
  applyLanguage();
  applyFilters();
})();
