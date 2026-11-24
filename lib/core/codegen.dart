import 'dart:convert';

import '../models/models.dart';
import 'auth.dart';

const codegenLanguages = {
  'curl': 'cURL',
  'http': 'HTTP',
  'python': 'Python - Requests',
  'fetch': 'JavaScript - Fetch',
  'axios': 'NodeJS - Axios',
  'go': 'Go - net/http',
  'csharp': 'C# - HttpClient',
  'java': 'Java - HttpClient',
  'powershell': 'PowerShell - Invoke-RestMethod',
};

String _sq(String s) => "'${s.replaceAll("'", "'\\''")}'";
String _dq(String s) => jsonEncode(s);

/// Generates a code snippet from a fully prepared request.
/// [r] is the resolved source request (used for multipart form fields).
String generateCode(String lang, PreparedRequest p, ApiRequest r) {
  final url = p.uri.toString();
  final multipart = r.body.mode == 'form-data' && r.type == RequestType.http;
  final headers = p.headers
      .where((h) => !(multipart && h.key.toLowerCase() == 'content-type'))
      .where((h) => h.key != 'User-Agent' || h.value != 'CourierRuntime/1.0')
      .toList();
  final body = multipart ? '' : utf8.decode(p.body, allowMalformed: true);
  final fields = r.body.formData.where((e) => e.enabled && e.key.isNotEmpty).toList();

  switch (lang) {
    case 'curl':
      final sb = StringBuffer("curl --location --request ${p.method} ${_sq(url)}");
      for (final h in headers) {
        sb.write(" \\\n--header ${_sq('${h.key}: ${h.value}')}");
      }
      if (multipart) {
        for (final f in fields) {
          sb.write(" \\\n--form ${_sq(f.type == 'file' ? '${f.key}=@"${f.value}"' : '${f.key}=${f.value}')}");
        }
      } else if (body.isNotEmpty) {
        sb.write(" \\\n--data-raw ${_sq(body)}");
      }
      return sb.toString();
    case 'http':
      final sb = StringBuffer('${p.method} ${p.uri.path.isEmpty ? '/' : p.uri.path}${p.uri.hasQuery ? '?${p.uri.query}' : ''} HTTP/1.1\n');
      sb.writeln('Host: ${p.uri.host}${p.uri.hasPort && p.uri.port != 80 && p.uri.port != 443 ? ':${p.uri.port}' : ''}');
      for (final h in p.headers) {
        sb.writeln('${h.key}: ${h.value}');
      }
      if (p.body.isNotEmpty) sb.writeln('Content-Length: ${p.body.length}');
      sb.writeln();
      sb.write(utf8.decode(p.body, allowMalformed: true));
      return sb.toString();
    case 'python':
      final sb = StringBuffer('import requests\n\nurl = ${_dq(url)}\n\n');
      if (multipart) {
        sb.writeln('payload = {${fields.where((f) => f.type != 'file').map((f) => '${_dq(f.key)}: ${_dq(f.value)}').join(', ')}}');
        sb.writeln('files = [${fields.where((f) => f.type == 'file').map((f) => '(${_dq(f.key)}, open(${_dq(f.value)}, "rb"))').join(', ')}]');
      } else {
        sb.writeln('payload = ${_dq(body)}');
      }
      sb.writeln('headers = {');
      for (final h in headers) {
        sb.writeln('  ${_dq(h.key)}: ${_dq(h.value)},');
      }
      sb.writeln('}\n');
      sb.writeln('response = requests.request(${_dq(p.method)}, url, headers=headers, data=payload${multipart ? ', files=files' : ''})\n');
      sb.write('print(response.text)');
      return sb.toString();
    case 'fetch':
      final sb = StringBuffer('const myHeaders = new Headers();\n');
      for (final h in headers) {
        sb.writeln('myHeaders.append(${_dq(h.key)}, ${_dq(h.value)});');
      }
      if (multipart) {
        sb.writeln('\nconst formdata = new FormData();');
        for (final f in fields) {
          sb.writeln(f.type == 'file'
              ? 'formdata.append(${_dq(f.key)}, fileInput.files[0], ${_dq(f.value)});'
              : 'formdata.append(${_dq(f.key)}, ${_dq(f.value)});');
        }
      } else if (body.isNotEmpty) {
        sb.writeln('\nconst raw = ${_dq(body)};');
      }
      sb.writeln('\nconst requestOptions = {');
      sb.writeln('  method: ${_dq(p.method)},');
      sb.writeln('  headers: myHeaders,');
      if (multipart) sb.writeln('  body: formdata,');
      if (!multipart && body.isNotEmpty) sb.writeln('  body: raw,');
      sb.writeln('  redirect: "follow"\n};\n');
      sb.write('fetch(${_dq(url)}, requestOptions)\n  .then((response) => response.text())\n  .then((result) => console.log(result))\n  .catch((error) => console.error(error));');
      return sb.toString();
    case 'axios':
      final sb = StringBuffer("const axios = require('axios');\n");
      if (multipart) {
        sb.writeln("const FormData = require('form-data');\nconst fs = require('fs');\nconst data = new FormData();");
        for (final f in fields) {
          sb.writeln(f.type == 'file'
              ? 'data.append(${_dq(f.key)}, fs.createReadStream(${_dq(f.value)}));'
              : 'data.append(${_dq(f.key)}, ${_dq(f.value)});');
        }
      } else {
        sb.writeln('const data = ${_dq(body)};');
      }
      sb.writeln('\nconst config = {');
      sb.writeln('  method: ${_dq(p.method.toLowerCase())},');
      sb.writeln('  maxBodyLength: Infinity,');
      sb.writeln('  url: ${_dq(url)},');
      sb.writeln('  headers: {');
      for (final h in headers) {
        sb.writeln('    ${_dq(h.key)}: ${_dq(h.value)},');
      }
      if (multipart) sb.writeln('    ...data.getHeaders()');
      sb.writeln('  },\n  data: data\n};\n');
      sb.write('axios.request(config)\n  .then((response) => console.log(JSON.stringify(response.data)))\n  .catch((error) => console.log(error));');
      return sb.toString();
    case 'go':
      final sb = StringBuffer('package main\n\nimport (\n  "fmt"\n  "io"\n  "net/http"\n  "strings"\n)\n\nfunc main() {\n');
      sb.writeln('  url := ${_dq(url)}');
      sb.writeln('  payload := strings.NewReader(${_dq(utf8.decode(p.body, allowMalformed: true))})\n');
      sb.writeln('  client := &http.Client{}');
      sb.writeln('  req, err := http.NewRequest(${_dq(p.method)}, url, payload)');
      sb.writeln('  if err != nil {\n    fmt.Println(err)\n    return\n  }');
      for (final h in p.headers) {
        sb.writeln('  req.Header.Add(${_dq(h.key)}, ${_dq(h.value)})');
      }
      sb.writeln('\n  res, err := client.Do(req)');
      sb.writeln('  if err != nil {\n    fmt.Println(err)\n    return\n  }\n  defer res.Body.Close()\n');
      sb.writeln('  body, err := io.ReadAll(res.Body)');
      sb.writeln('  if err != nil {\n    fmt.Println(err)\n    return\n  }\n  fmt.Println(string(body))\n}');
      return sb.toString();
    case 'csharp':
      final ct = p.header('content-type') ?? 'text/plain';
      final sb = StringBuffer('var client = new HttpClient();\n');
      sb.writeln('var request = new HttpRequestMessage(new HttpMethod(${_dq(p.method)}), ${_dq(url)});');
      for (final h in p.headers.where((h) => h.key.toLowerCase() != 'content-type')) {
        sb.writeln('request.Headers.TryAddWithoutValidation(${_dq(h.key)}, ${_dq(h.value)});');
      }
      if (p.body.isNotEmpty) {
        sb.writeln('request.Content = new StringContent(${_dq(utf8.decode(p.body, allowMalformed: true))});');
        sb.writeln('request.Content.Headers.Remove("Content-Type");');
        sb.writeln('request.Content.Headers.TryAddWithoutValidation("Content-Type", ${_dq(ct)});');
      }
      sb.writeln('var response = await client.SendAsync(request);');
      sb.write('Console.WriteLine(await response.Content.ReadAsStringAsync());');
      return sb.toString();
    case 'java':
      final sb = StringBuffer('HttpClient client = HttpClient.newHttpClient();\n');
      sb.writeln('HttpRequest request = HttpRequest.newBuilder()');
      sb.writeln('    .uri(URI.create(${_dq(url)}))');
      for (final h in p.headers.where((h) => !const {'host', 'connection', 'content-length'}.contains(h.key.toLowerCase()))) {
        sb.writeln('    .header(${_dq(h.key)}, ${_dq(h.value)})');
      }
      sb.writeln(p.body.isEmpty
          ? '    .method(${_dq(p.method)}, HttpRequest.BodyPublishers.noBody())'
          : '    .method(${_dq(p.method)}, HttpRequest.BodyPublishers.ofString(${_dq(utf8.decode(p.body, allowMalformed: true))}))');
      sb.writeln('    .build();');
      sb.writeln('HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString());');
      sb.write('System.out.println(response.body());');
      return sb.toString();
    case 'powershell':
      final sb = StringBuffer('\$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"\n');
      for (final h in p.headers) {
        sb.writeln('\$headers.Add(${_dq(h.key)}, ${_dq(h.value)})');
      }
      if (p.body.isNotEmpty) sb.writeln('\$body = @"\n${utf8.decode(p.body, allowMalformed: true)}\n"@');
      sb.write('\$response = Invoke-RestMethod ${_sq(url)} -Method ${p.method[0]}${p.method.substring(1).toLowerCase()} -Headers \$headers${p.body.isNotEmpty ? ' -Body \$body' : ''}\n');
      sb.write('\$response | ConvertTo-Json');
      return sb.toString();
  }
  return '';
}
