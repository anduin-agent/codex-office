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
    untitled: ['未命名会话', 'Untitled session']
  };

  const byId = id => document.getElementById(id);
  const fields = {
    from: byId('usage-from'),
    to: byId('usage-to'),
    project: byId('usage-project'),
    model: byId('usage-model')
  };
  const list = byId('usage-session-list');
  const detail = byId('session-detail');
  const results = detail.parentElement;
  const status = byId('usage-status');
  const dateKey = date => [date.getFullYear(), date.getMonth() + 1, date.getDate()]
    .map((part, index) => String(part).padStart(index ? 2 : 4, '0')).join('-');
  const validDate = value => /^\d{4}-\d{2}-\d{2}$/.test(value);
  const validCount = value => Number.isSafeInteger(value) && value >= 0;
  const sessionID = /^[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}$/i;
  const pageSize = 100;
  const maxRetries = 20;
  let language = window.officeInitialLanguage === 'en' ? 'en' : 'zh-CN';
  const formatter = new Intl.NumberFormat('en-US');
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

  const t = key => copy[key][language === 'en' ? 1 : 0];
  const number = value => validCount(value) ? formatter.format(value) : '—';
  const tokens = value => validCount(value) ? number(value) + ' tokens' : '—';
  const sessions = count => language === 'en'
    ? number(count) + (count === 1 ? ' session' : ' sessions') : number(count) + ' 个会话';

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
    return [...list.querySelectorAll('[data-session-id]')].find(row => row.dataset.sessionId === selectedSession);
  }

  function closeDetail(focus = false) {
    const row = selectedRow();
    row?.setAttribute('aria-expanded', 'false');
    selectedSession = '';
    detail.hidden = true;
    results.removeAttribute('data-session-open');
    if (focus) row?.focus();
  }

  function showDetail(session, focus = true) {
    selectedRow()?.setAttribute('aria-expanded', 'false');
    selectedSession = session.id;
    selectedRow()?.setAttribute('aria-expanded', 'true');
    const title = byId('session-title');
    title.textContent = session.title || t('untitled');
    byId('session-tokens').textContent = tokens(session.tokens);
    byId('session-date-range').textContent = dates.format(new Date(activeFilters.from)) + ' – ' +
      dates.format(new Date(activeFilters.to));
    byId('session-project').textContent = session.project || t('unknownProject');
    const modelField = byId('session-models');
    const modelTotals = Array.isArray(session.model_totals) ? session.model_totals
      .filter(item => typeof item?.title === 'string' && validCount(item.tokens)) : [];
    if (modelTotals.length) {
      const breakdown = document.createElement('ul');
      breakdown.className = 'model-totals';
      for (const {title: model, tokens: total} of modelTotals) {
        const item = document.createElement('li');
        const name = document.createElement('span');
        const count = document.createElement('span');
        name.textContent = model || t('unknownModel');
        count.textContent = number(total);
        item.append(name, count);
        breakdown.append(item);
      }
      modelField.replaceChildren(breakdown);
    } else {
      modelField.textContent = (session.models ?? []).join(', ') || t('unknownModel');
    }
    detail.hidden = false;
    results.setAttribute('data-session-open', '');
    if (focus) title.focus();
  }

  function renderResults(data) {
    const rows = Array.isArray(data?.sessions) ? data.sessions.filter(item =>
      typeof item?.id === 'string' && sessionID.test(item.id)) : [];
    const hasResult = Boolean(data);
    byId('usage-total-tokens').textContent = tokens(data?.total_tokens);
    byId('usage-session-count').textContent = hasResult ? sessions(data.total_sessions) : '';
    const fragment = document.createDocumentFragment();
    for (const row of rows) {
      const item = document.createElement('li');
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'session-row';
      button.dataset.sessionId = row.id;
      button.setAttribute('aria-controls', 'session-detail');
      button.setAttribute('aria-expanded', 'false');
      const title = document.createElement('span');
      title.textContent = row.title || t('untitled');
      title.title = title.textContent;
      const meta = document.createElement('span');
      meta.className = 'meta';
      meta.textContent = [row.project || t('unknownProject'), (row.models ?? []).join(', ') || t('unknownModel')].join(' · ');
      meta.title = meta.textContent;
      const total = document.createElement('strong');
      total.textContent = number(row.tokens);
      button.append(title, meta, total);
      button.addEventListener('click', () => showDetail(row));
      item.append(button);
      fragment.append(item);
    }
    const focusedSession = document.activeElement?.dataset.sessionId;
    list.replaceChildren(fragment);
    const selected = rows.find(row => row.id === selectedSession);
    if (selected) showDetail(selected, false);
    else closeDetail();
    if (focusedSession) {
      [...list.querySelectorAll('[data-session-id]')].find(row => row.dataset.sessionId === focusedSession)?.focus();
    }
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
    const {from, to, project, model} = Object.fromEntries(Object.entries(fields).map(([key, field]) => [key, field.value]));
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
    activeFilters = {from, to, project, model, offset: 0};
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
  byId('close-session-detail').addEventListener('click', () => closeDetail(true));
  byId('open-codex-session').addEventListener('click', () => {
    if (selectedSession) bridge({action: 'openChat', id: selectedSession});
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
