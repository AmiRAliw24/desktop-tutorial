(() => {
  const T = {
    en: { title: "Server Monitor", signin_sub: "Sign in to continue", user: "Username", password: "Password", signin: "Sign in", bad: "Wrong username or password", net: "Could not reach the server" },
    fa: { title: "مانیتورینگ سرور", signin_sub: "برای ادامه وارد شوید", user: "نام کاربری", password: "رمز عبور", signin: "ورود", bad: "نام کاربری یا رمز عبور اشتباه است", net: "ارتباط با سرور برقرار نشد" },
  };
  let lang = "en", theme = "dark";
  try { lang = localStorage.getItem("lang") || lang; theme = localStorage.getItem("theme") || theme; } catch (e) { /* storage blocked */ }
  if (!T[lang]) lang = "en";
  document.documentElement.dataset.theme = theme;
  document.documentElement.lang = lang;
  document.documentElement.dir = lang === "fa" ? "rtl" : "ltr";
  document.querySelectorAll("[data-i18n]").forEach((el) => { el.textContent = T[lang][el.dataset.i18n]; });
  document.title = T[lang].signin + " - " + T[lang].title;

  const form = document.getElementById("form"), err = document.getElementById("error"), btn = document.getElementById("submit");
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    err.textContent = "";
    btn.disabled = true;
    try {
      const r = await fetch("/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ user: form.user.value, password: form.password.value }),
      });
      if (r.ok) { location.replace("/"); return; }
      err.textContent = T[lang].bad;
    } catch (x) {
      err.textContent = T[lang].net;
    }
    btn.disabled = false;
    form.password.select();
  });
})();
