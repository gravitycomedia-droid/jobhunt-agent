/// Phase 6 (form autofill) — mirrors server/models/form.py.
/// The agent fills, the human reviews and taps submit: nothing in the app
/// ever POSTs to a form endpoint; the deliverable is a prefill URL opened
/// in the user's own browser.
class FormQuestion {
  final String entryId;
  final String text;
  final String type; // short | paragraph | choice | checkbox | dropdown | date | time | scale | file_upload | unknown
  final List<String> options;
  final bool required;

  const FormQuestion({
    required this.entryId,
    required this.text,
    required this.type,
    this.options = const [],
    this.required = false,
  });

  bool get isFileUpload => type == 'file_upload';

  factory FormQuestion.fromJson(Map<String, dynamic> json) {
    return FormQuestion(
      entryId: json['entry_id'] as String? ?? '',
      text: json['text'] as String,
      type: json['type'] as String? ?? 'unknown',
      options: (json['options'] as List? ?? []).map((o) => o as String).toList(),
      required: json['required'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'entry_id': entryId,
        'text': text,
        'type': type,
        'options': options,
        'required': required,
      };
}

class FormSchemaModel {
  final String title;
  final String? description;
  final List<FormQuestion> questions;
  final String formUrl;
  final String source; // google_form | llm_extracted

  const FormSchemaModel({
    required this.title,
    this.description,
    required this.questions,
    required this.formUrl,
    required this.source,
  });

  bool get isLlmExtracted => source == 'llm_extracted';

  factory FormSchemaModel.fromJson(Map<String, dynamic> json) {
    return FormSchemaModel(
      title: json['title'] as String,
      description: json['description'] as String?,
      questions: (json['questions'] as List).map((q) => FormQuestion.fromJson((q as Map).cast<String, dynamic>())).toList(),
      formUrl: json['form_url'] as String? ?? '',
      source: json['source'] as String? ?? 'google_form',
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'description': description,
        'questions': questions.map((q) => q.toJson()).toList(),
        'form_url': formUrl,
        'source': source,
      };
}

/// POST /forms/parse response: the schema plus (when the form's description
/// embedded a full JD) the job row created for the tailoring branch.
class ParsedForm {
  final FormSchemaModel form;
  final String? jobId;
  final String? jobTitle;

  const ParsedForm({required this.form, this.jobId, this.jobTitle});

  factory ParsedForm.fromJson(Map<String, dynamic> json) {
    return ParsedForm(
      form: FormSchemaModel.fromJson((json['form'] as Map).cast<String, dynamic>()),
      jobId: json['job_id'] as String?,
      jobTitle: json['job_title'] as String?,
    );
  }
}

class FormAnswer {
  final String entryId;
  final String question;

  /// String, List of strings (checkbox), or null — null means "the profile
  /// doesn't contain this fact", which the UI flags for manual entry.
  Object? answer;
  final double confidence;
  final String? sourceField;
  final bool guardrailPass;

  FormAnswer({
    required this.entryId,
    required this.question,
    this.answer,
    required this.confidence,
    this.sourceField,
    this.guardrailPass = true,
  });

  bool get needsAttention => answer == null || confidence < 0.5 || !guardrailPass;

  String get answerText {
    final a = answer;
    if (a == null) return '';
    if (a is List) return a.join(', ');
    return a.toString();
  }

  factory FormAnswer.fromJson(Map<String, dynamic> json) {
    return FormAnswer(
      entryId: json['entry_id'] as String? ?? '',
      question: json['question'] as String,
      answer: json['answer'],
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      sourceField: json['source_field'] as String?,
      guardrailPass: json['guardrail_pass'] as bool? ?? true,
    );
  }
}

/// POST /forms/fill response.
class FormFillResult {
  final List<FormAnswer> answers;
  final String? prefillUrl;

  const FormFillResult({required this.answers, this.prefillUrl});

  factory FormFillResult.fromJson(Map<String, dynamic> json) {
    return FormFillResult(
      answers: (json['answers'] as List).map((a) => FormAnswer.fromJson((a as Map).cast<String, dynamic>())).toList(),
      prefillUrl: json['prefill_url'] as String?,
    );
  }
}
