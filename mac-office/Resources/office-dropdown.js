(() => {
  'use strict';

  const controls = new WeakMap();
  let openControl = null;
  let sequence = 0;

  function optionDisabled(option) {
    return option.disabled || (option.parentElement?.tagName === 'OPTGROUP' && option.parentElement.disabled);
  }

  function labelFor(select) {
    const references = select.getAttribute('aria-labelledby');
    if (references) {
      return references.split(/\s+/).map(id => document.getElementById(id)?.textContent.trim()).filter(Boolean).join(' ');
    }
    const explicit = select.getAttribute('aria-label');
    if (explicit) return explicit;
    return [...select.labels].map(label => [...label.childNodes]
      .filter(node => node.nodeType === Node.TEXT_NODE ||
        (node.nodeType === Node.ELEMENT_NODE && !node.matches('select, .office-dropdown, small')))
      .map(node => node.textContent.trim()).filter(Boolean).join(' ')).filter(Boolean).join(' ');
  }

  function close(control = openControl) {
    if (!control || control !== openControl) return;
    openControl = null;
    control.list.hidden = true;
    control.trigger.setAttribute('aria-expanded', 'false');
    control.trigger.removeAttribute('aria-activedescendant');
    control.query = '';
    control.queryAt = 0;
  }

  function place(control) {
    const rect = control.trigger.getBoundingClientRect();
    const viewport = document.documentElement;
    const margin = 8;
    const gap = 5;
    if (!rect.width || !rect.height || rect.bottom <= 0 || rect.top >= viewport.clientHeight) {
      close(control);
      return;
    }
    const below = viewport.clientHeight - rect.bottom - gap - margin;
    const above = rect.top - gap - margin;
    const preferAbove = below < Math.min(control.list.scrollHeight, 150) && above > below;
    const width = Math.min(Math.max(rect.width, 168), viewport.clientWidth - 2 * margin);
    Object.assign(control.list.style, {
      left: Math.max(margin, Math.min(rect.left, viewport.clientWidth - width - margin)) + 'px',
      width: width + 'px',
      maxHeight: Math.max(0, Math.min(preferAbove ? above : below, 250)) + 'px',
      top: preferAbove ? 'auto' : (rect.bottom + gap) + 'px',
      bottom: preferAbove ? (viewport.clientHeight - rect.top + gap) + 'px' : 'auto'
    });
  }

  function highlight(control, index, scroll = false) {
    const row = control.rows[index];
    if (!row) return;
    control.rows[control.active]?.removeAttribute('data-active');
    control.active = index;
    row.setAttribute('data-active', '');
    control.trigger.setAttribute('aria-activedescendant', row.id);
    if (scroll) {
      const listRect = control.list.getBoundingClientRect();
      const rowRect = row.getBoundingClientRect();
      if (rowRect.top < listRect.top) control.list.scrollTop += rowRect.top - listRect.top - 4;
      if (rowRect.bottom > listRect.bottom) control.list.scrollTop += rowRect.bottom - listRect.bottom + 4;
    }
  }

  function sync(control) {
    const {select, trigger, value, list} = control;
    const selected = select.selectedIndex;
    const selectedText = select.options[selected]?.label ?? '';
    const label = labelFor(select);
    if (value.textContent !== selectedText) value.textContent = selectedText;
    if (trigger.title !== select.title) trigger.title = select.title;
    const accessibleName = [label, selectedText].filter(Boolean).join(' · ');
    if (trigger.getAttribute('aria-label') !== accessibleName) trigger.setAttribute('aria-label', accessibleName);
    if (list.getAttribute('aria-label') !== label) list.setAttribute('aria-label', label);

    const options = [...select.options].map(option => [option.value, option.label, optionDisabled(option), option.hidden]);
    const enabled = options.flatMap(([, , disabled, hidden], index) => disabled || hidden ? [] : [index]);
    const disabled = select.matches(':disabled') || !enabled.length;
    trigger.setAttribute('aria-disabled', String(disabled));
    trigger.tabIndex = disabled ? -1 : 0;
    control.enabled = enabled;
    const key = JSON.stringify([selected, options]);
    if (key !== control.key) {
      control.key = key;
      control.rows = options.map(([, name, unavailable, hidden], index) => {
        const row = document.createElement('div');
        row.className = 'office-dropdown-option';
        row.id = list.id + '-' + index;
        row.dataset.index = index;
        row.setAttribute('role', 'option');
        row.setAttribute('aria-selected', String(index === selected));
        if (unavailable) row.setAttribute('aria-disabled', 'true');
        row.hidden = hidden;
        const caption = document.createElement('span');
        caption.textContent = name;
        row.append(caption);
        row.title = name;
        return row;
      });
      list.replaceChildren(...control.rows);
      if (openControl === control && !disabled) {
        place(control);
        if (openControl === control) {
          highlight(control, enabled.includes(control.active) ? control.active :
            enabled.includes(selected) ? selected : enabled[0], true);
        }
      }
    }
    if (disabled) close(control);
  }

  function open(control, fromEnd = false) {
    sync(control);
    if (!control.enabled.length || control.trigger.getAttribute('aria-disabled') === 'true') return false;
    close();
    openControl = control;
    control.trigger.setAttribute('aria-expanded', 'true');
    control.list.hidden = false;
    place(control);
    if (openControl !== control) return false;
    const {selectedIndex} = control.select;
    highlight(control, control.enabled.includes(selectedIndex) ? selectedIndex :
      fromEnd ? control.enabled.at(-1) : control.enabled[0], true);
    return true;
  }

  function choose(control, index) {
    if (!control.enabled.includes(index)) return;
    const changed = index !== control.select.selectedIndex;
    close(control);
    if (changed) {
      control.select.selectedIndex = index;
      control.select.dispatchEvent(new Event('input', {bubbles: true}));
      control.select.dispatchEvent(new Event('change', {bubbles: true}));
    }
    sync(control);
  }

  function handleKey(control, event) {
    if (event.isComposing) return;
    const isOpen = openControl === control;
    const key = event.key;
    if (key === 'Tab') {
      close(control);
      return;
    }
    if (key === 'Escape') {
      if (!isOpen) return;
      event.preventDefault();
      event.stopPropagation();
      close(control);
      return;
    }
    if (key === 'Enter' || key === ' ') {
      event.preventDefault();
      if (isOpen) choose(control, control.active);
      else open(control);
      return;
    }
    if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(key)) {
      event.preventDefault();
      const moveBack = key === 'ArrowUp';
      if (!isOpen && !open(control, moveBack || key === 'End')) return;
      const options = control.enabled;
      const position = options.indexOf(control.active);
      if (key === 'Home') highlight(control, options[0], true);
      else if (key === 'End') highlight(control, options.at(-1), true);
      else if (isOpen) highlight(control, options[Math.max(0, Math.min(options.length - 1, position + (moveBack ? -1 : 1)))], true);
      return;
    }
    if (key.length !== 1 || event.ctrlKey || event.altKey || event.metaKey) return;
    if (!isOpen && !open(control)) return;
    const now = performance.now();
    const search = key.toLocaleLowerCase();
    control.query = now - control.queryAt < 700 ? control.query + search : search;
    control.queryAt = now;
    const options = control.enabled;
    const position = options.indexOf(control.active);
    const ordered = [...options.slice(position + 1), ...options.slice(0, position + 1)];
    const matches = (index, prefix) => control.select.options[index].label.trim().toLocaleLowerCase().startsWith(prefix);
    let next = ordered.find(index => matches(index, control.query));
    if (next === undefined && [...control.query].every(char => char === search)) {
      next = ordered.find(index => matches(index, search));
    }
    if (next !== undefined) highlight(control, next, true);
    event.preventDefault();
  }

  function enhance(select) {
    const trigger = document.createElement('span');
    trigger.className = 'office-dropdown';
    trigger.setAttribute('role', 'combobox');
    trigger.setAttribute('aria-haspopup', 'listbox');
    trigger.setAttribute('aria-expanded', 'false');
    const value = document.createElement('span');
    value.className = 'office-dropdown-value';
    trigger.append(value);
    const list = document.createElement('div');
    list.className = 'office-dropdown-list';
    list.id = 'office-dropdown-list-' + ++sequence;
    list.setAttribute('role', 'listbox');
    list.hidden = true;
    trigger.setAttribute('aria-controls', list.id);
    const control = {select, trigger, value, list, rows: [], enabled: [], active: -1, query: '', queryAt: 0};
    controls.set(select, control);
    select.after(trigger);
    (select.closest('dialog') ?? document.body).append(list);
    select.hidden = true;
    trigger.addEventListener('click', event => {
      // Implicit labels must not activate the hidden native control.
      event.preventDefault();
      if (trigger.getAttribute('aria-disabled') === 'true') return;
      trigger.focus({preventScroll: true});
      if (openControl === control) close(control);
      else open(control);
    });
    for (const label of select.labels) {
      label.addEventListener('click', event => {
        if (event.defaultPrevented || event.target.closest?.('button, input, a')) return;
        event.preventDefault();
        if (trigger.getAttribute('aria-disabled') === 'true') return;
        trigger.focus();
        open(control);
      });
    }
    trigger.addEventListener('keydown', event => handleKey(control, event));
    trigger.addEventListener('blur', () => close(control));
    list.addEventListener('mousedown', event => {
      if (event.target.closest('.office-dropdown-option')) event.preventDefault();
    });
    list.addEventListener('click', event => {
      const row = event.target.closest('.office-dropdown-option');
      if (row) choose(control, Number(row.dataset.index));
    });
    list.addEventListener('pointermove', event => {
      if (event.pointerType === 'touch') return;
      const index = Number(event.target.closest('.office-dropdown-option')?.dataset.index);
      if (control.enabled.includes(index) && index !== control.active) highlight(control, index);
    });
    select.addEventListener('change', () => sync(control));
    return control;
  }

  function refresh() {
    for (const select of document.querySelectorAll('select:not([multiple])')) {
      sync(controls.get(select) ?? enhance(select));
    }
  }

  function setup() {
    refresh();
    new MutationObserver(records => {
      if (records.some(({type, target, addedNodes}) => {
        const element = target.nodeType === Node.ELEMENT_NODE ? target : target.parentElement;
        return element?.closest('select') || (type === 'attributes' && element?.matches('fieldset')) ||
          [...addedNodes].some(node => node.nodeType === Node.ELEMENT_NODE && (node.matches('select') || node.querySelector('select')));
      })) refresh();
    }).observe(document.body, {subtree: true, childList: true, characterData: true, attributes: true,
      attributeFilter: ['disabled', 'selected', 'label', 'hidden', 'aria-label', 'aria-labelledby']});
    document.addEventListener('pointerdown', event => {
      if (!openControl || openControl.trigger.contains(event.target) || openControl.list.contains(event.target)) return;
      close();
    }, true);
    document.addEventListener('close', event => {
      if (event.target.contains(openControl?.trigger ?? null)) close();
    }, true);
    document.addEventListener('scroll', event => {
      const control = openControl;
      const scroller = event.target;
      if (!control || scroller === control.list) return;
      if (scroller instanceof Element && scroller.contains(control.trigger)) {
        const field = control.trigger.getBoundingClientRect();
        const region = scroller.getBoundingClientRect();
        if (field.bottom <= region.top || field.top >= region.bottom) {
          close(control);
          return;
        }
      }
      place(control);
    }, {capture: true, passive: true});
    window.addEventListener('resize', () => { if (openControl) place(openControl); });
  }

  window.officeDropdowns = {
    refresh,
    remove(select) {
      const control = controls.get(select);
      if (!control) return;
      close(control);
      control.list.remove();
      control.trigger.remove();
      controls.delete(select);
    },
    focus(select) { (controls.get(select)?.trigger ?? select).focus(); }
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', setup, {once: true});
  else setup();
})();
