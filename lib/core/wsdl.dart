import 'package:xml/xml.dart';

class SoapOperation {
  final String name;
  final String soapAction;

  /// '1.1' | '1.2'
  final String version;
  final String endpoint;
  final String envelope;
  SoapOperation(this.name, this.soapAction, this.version, this.endpoint, this.envelope);
}

const _soap11 = 'http://schemas.xmlsoap.org/wsdl/soap/';
const _soap12 = 'http://schemas.xmlsoap.org/wsdl/soap12/';

String _local(String? qname) => qname == null ? '' : qname.contains(':') ? qname.split(':').last : qname;

/// Parses a WSDL 1.1 document into invokable operations with generated envelopes.
List<SoapOperation> parseWsdl(String source) {
  final doc = XmlDocument.parse(source);
  final defs = doc.rootElement;
  final tns = defs.getAttribute('targetNamespace') ?? '';
  Iterable<XmlElement> all(String local) => doc.descendants.whereType<XmlElement>().where((e) => e.name.local == local);

  // Schema lookup tables.
  final elements = <String, XmlElement>{};
  final complexTypes = <String, XmlElement>{};
  final elementNs = <String, String>{};
  for (final schema in all('schema')) {
    final sns = schema.getAttribute('targetNamespace') ?? tns;
    for (final c in schema.childElements) {
      final n = c.getAttribute('name');
      if (n == null) continue;
      if (c.name.local == 'element') {
        elements[n] = c;
        elementNs[n] = sns;
      }
      if (c.name.local == 'complexType') complexTypes[n] = c;
    }
  }

  // message name -> (element or part list)
  final messages = <String, XmlElement>{};
  for (final m in all('message')) {
    messages[m.getAttribute('name') ?? ''] = m;
  }

  // portType op -> input message
  final opInput = <String, String>{};
  for (final pt in all('portType')) {
    for (final op in pt.childElements.where((e) => e.name.local == 'operation')) {
      final input = op.childElements.where((e) => e.name.local == 'input').firstOrNull;
      opInput[op.getAttribute('name') ?? ''] = _local(input?.getAttribute('message'));
    }
  }

  // binding name -> address/version
  final bindingInfo = <String, (String, String)>{};
  for (final port in all('port')) {
    final addr = port.childElements.where((e) => e.name.local == 'address').firstOrNull;
    if (addr == null) continue;
    final v = addr.name.namespaceUri == _soap12 ? '1.2' : '1.1';
    bindingInfo[_local(port.getAttribute('binding'))] = (addr.getAttribute('location') ?? '', v);
  }

  final ops = <SoapOperation>[];
  final seen = <String>{};
  for (final b in all('binding')) {
    final soapBinding = b.childElements.where((e) => e.name.local == 'binding').firstOrNull;
    if (soapBinding == null) continue;
    final ns = soapBinding.name.namespaceUri;
    if (ns != _soap11 && ns != _soap12) continue;
    final version = ns == _soap12 ? '1.2' : '1.1';
    final info = bindingInfo[b.getAttribute('name') ?? ''];
    for (final op in b.childElements.where((e) => e.name.local == 'operation')) {
      final name = op.getAttribute('name') ?? '';
      final key = '$name/$version';
      if (seen.contains(key)) continue;
      seen.add(key);
      final soapOp = op.childElements.where((e) => e.name.local == 'operation').firstOrNull;
      final action = soapOp?.getAttribute('soapAction') ?? '';
      final body = _bodyFor(opInput[name] ?? '', messages, elements, elementNs, complexTypes, tns, name);
      final envNs = version == '1.2' ? 'http://www.w3.org/2003/05/soap-envelope' : 'http://schemas.xmlsoap.org/soap/envelope/';
      final envelope = '<?xml version="1.0" encoding="utf-8"?>\n'
          '<soap:Envelope xmlns:soap="$envNs">\n'
          '  <soap:Header/>\n'
          '  <soap:Body>\n$body'
          '  </soap:Body>\n'
          '</soap:Envelope>';
      ops.add(SoapOperation(name, action, version, info?.$1 ?? '', envelope));
    }
  }
  return ops;
}

String _bodyFor(String msgName, Map<String, XmlElement> messages, Map<String, XmlElement> elements,
    Map<String, String> elementNs, Map<String, XmlElement> complexTypes, String tns, String opName) {
  final msg = messages[msgName];
  final parts = msg?.childElements.where((e) => e.name.local == 'part').toList() ?? [];
  final sb = StringBuffer();
  if (parts.length == 1 && parts.first.getAttribute('element') != null) {
    final elName = _local(parts.first.getAttribute('element'));
    final ns = elementNs[elName] ?? tns;
    sb.writeln('    <tns:$elName xmlns:tns="$ns">');
    final el = elements[elName];
    if (el != null) _children(el, complexTypes, elements, sb, 3, 0);
    sb.writeln('    </tns:$elName>');
  } else {
    // RPC style: wrapper named after the operation, one child per part.
    sb.writeln('    <tns:$opName xmlns:tns="$tns">');
    for (final p in parts) {
      sb.writeln('      <${p.getAttribute('name')}>?</${p.getAttribute('name')}>');
    }
    sb.writeln('    </tns:$opName>');
  }
  return sb.toString();
}

void _children(XmlElement el, Map<String, XmlElement> types, Map<String, XmlElement> elements, StringBuffer sb, int indent, int depth) {
  if (depth > 5) return;
  XmlElement? ct = el.childElements.where((e) => e.name.local == 'complexType').firstOrNull;
  final typeRef = _local(el.getAttribute('type'));
  ct ??= types[typeRef];
  if (ct == null) return;
  final pad = '  ' * indent;
  final fields = ct.descendants.whereType<XmlElement>().where((e) => e.name.local == 'element');
  for (final f in fields) {
    final ref = f.getAttribute('ref');
    final target = ref != null ? elements[_local(ref)] : f;
    final name = ref != null ? _local(ref) : f.getAttribute('name');
    if (name == null || target == null) continue;
    // Skip elements nested inside a child complexType (handled recursively).
    if (f.ancestors.whereType<XmlElement>().where((a) => a.name.local == 'complexType').first != ct) continue;
    final subType = _local(target.getAttribute('type'));
    final hasComplex = types.containsKey(subType) || target.childElements.any((e) => e.name.local == 'complexType');
    if (hasComplex) {
      sb.writeln('$pad<tns:$name>');
      _children(target, types, elements, sb, indent + 1, depth + 1);
      sb.writeln('$pad</tns:$name>');
    } else {
      sb.writeln('$pad<tns:$name>?</tns:$name>');
    }
  }
}
